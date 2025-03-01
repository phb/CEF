// Copyright (c) 2008 The Chromium Embedded Framework Authors.
// Portions copyright (c) 2006-2008 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "browser_request_context.h"
#include "browser_file_system.h"
#include "browser_persistent_cookie_store.h"
#include "browser_resource_loader_bridge.h"
#include "cef_context.h"
#include "cef_thread.h"

#include "base/compiler_specific.h"
#include "base/file_path.h"
#include "base/file_util.h"
#include "build/build_config.h"
#include "net/base/cert_verifier.h"
#include "net/base/cookie_monster.h"
#include "net/base/default_origin_bound_cert_store.h"
#include "net/base/host_resolver.h"
#include "net/base/origin_bound_cert_service.h"
#include "net/base/ssl_config_service_defaults.h"
#include "net/ftp/ftp_network_layer.h"
#include "net/http/http_auth_handler_factory.h"
#include "net/http/http_server_properties_impl.h"
#include "net/proxy/proxy_config_service.h"
#include "net/proxy/proxy_config_service_fixed.h"
#include "net/proxy/proxy_service.h"
#include "net/url_request/url_request_job_factory.h"
#include "third_party/WebKit/Source/WebKit/chromium/public/WebKit.h"
#include "third_party/WebKit/Source/WebKit/chromium/public/WebKitPlatformSupport.h"
#include "webkit/blob/blob_storage_controller.h"
#include "webkit/blob/blob_url_request_job_factory.h"
#include "webkit/fileapi/file_system_context.h"
#include "webkit/fileapi/file_system_url_request_job_factory.h"
#include "webkit/glue/webkit_glue.h"

#if defined(OS_WIN)

#include <winhttp.h>
#pragma comment(lib, "winhttp.lib")

namespace {

// ProxyConfigService implementation that does nothing.
class ProxyConfigServiceNull : public net::ProxyConfigService {
public:
  ProxyConfigServiceNull() {}
  virtual void AddObserver(Observer* observer) {}
  virtual void RemoveObserver(Observer* observer) {}
  virtual ProxyConfigService::ConfigAvailability
      GetLatestProxyConfig(net::ProxyConfig* config)
      { return ProxyConfigService::CONFIG_VALID; }
  virtual void OnLazyPoll() {}
};

} // namespace

#endif // defined(OS_WIN)

BrowserRequestContext::BrowserRequestContext() 
    : ALLOW_THIS_IN_INITIALIZER_LIST(storage_(this)),
      accept_all_cookies_(true) {
  Init(FilePath(), net::HttpCache::NORMAL, false);
}

BrowserRequestContext::BrowserRequestContext(
    const FilePath& cache_path,
    net::HttpCache::Mode cache_mode,
    bool no_proxy)
    : ALLOW_THIS_IN_INITIALIZER_LIST(storage_(this)),
      accept_all_cookies_(true) {
  Init(cache_path, cache_mode, no_proxy);
}

void BrowserRequestContext::Init(
    const FilePath& cache_path,
    net::HttpCache::Mode cache_mode,
    bool no_proxy) {
  // Create the |cache_path| directory if necessary.
  bool cache_path_valid = false;
  if (!cache_path.empty()) {
    if (file_util::CreateDirectory(cache_path))
      cache_path_valid = true;
    else
      NOTREACHED() << "The cache_path directory could not be created";
  }

  scoped_refptr<BrowserPersistentCookieStore> persistent_store;
  if (cache_path_valid) {
    const FilePath& cookie_path = cache_path.AppendASCII("Cookies");
    persistent_store = new BrowserPersistentCookieStore(cookie_path);
  }

  storage_.set_cookie_store(
      new net::CookieMonster(persistent_store.get(), NULL));
  storage_.set_origin_bound_cert_service(new net::OriginBoundCertService(
      new net::DefaultOriginBoundCertStore(NULL)));

  // hard-code A-L and A-C for test shells
  set_accept_language("en-us,en");
  set_accept_charset("iso-8859-1,*,utf-8");

#if defined(OS_WIN)
  const CefSettings& settings = _Context->settings();
  if (!settings.auto_detect_proxy_settings_enabled) {
    // Using the system proxy resolver on Windows when "Automatically detect
    // settings" (auto-detection) is checked under LAN Settings can hurt
    // resource loading performance because the call to WinHttpGetProxyForUrl in
    // proxy_resolver_winhttp.cc will block the IO thread.  This is especially
    // true for Windows 7 where auto-detection is checked by default. To avoid
    // slow resource loading on Windows we only use the system proxy resolver if
    // auto-detection is unchecked.
    WINHTTP_CURRENT_USER_IE_PROXY_CONFIG ie_config = {0};
    if (WinHttpGetIEProxyConfigForCurrentUser(&ie_config)) {
      if (ie_config.fAutoDetect == TRUE) {
        storage_.set_proxy_service(net::ProxyService::CreateWithoutProxyResolver(
            new ProxyConfigServiceNull(), NULL));
      }

      if (ie_config.lpszAutoConfigUrl)
        GlobalFree(ie_config.lpszAutoConfigUrl);
      if (ie_config.lpszProxy)
        GlobalFree(ie_config.lpszProxy);
      if (ie_config.lpszProxyBypass)
        GlobalFree(ie_config.lpszProxyBypass);
    }
  }
#endif // defined(OS_WIN)
  
  if (!proxy_service()) {
#if defined(OS_POSIX) && !defined(OS_MACOSX)
    // Use no proxy to avoid ProxyConfigServiceLinux.
    // Enabling use of the ProxyConfigServiceLinux requires:
    // -Calling from a thread with a TYPE_UI MessageLoop,
    // -If at all possible, passing in a pointer to the IO thread's MessageLoop,
    // -Keep in mind that proxy auto configuration is also
    //  non-functional on linux in this context because of v8 threading
    //  issues.
    // TODO(port): rename "linux" to some nonspecific unix.
    scoped_ptr<net::ProxyConfigService> proxy_config_service(
        new net::ProxyConfigServiceFixed(net::ProxyConfig()));
#else
    // Use the system proxy settings.
    scoped_ptr<net::ProxyConfigService> proxy_config_service(
        net::ProxyService::CreateSystemProxyConfigService(
            MessageLoop::current(), NULL));
#endif

    storage_.set_proxy_service(net::ProxyService::CreateUsingSystemProxyResolver(
        proxy_config_service.release(), 0, NULL));
  }

  storage_.set_host_resolver(
      net::CreateSystemHostResolver(net::HostResolver::kDefaultParallelism,
                                    net::HostResolver::kDefaultRetryAttempts,
                                    NULL));
  storage_.set_cert_verifier(new net::CertVerifier);
  storage_.set_ssl_config_service(new net::SSLConfigServiceDefaults);

  // Add support for single sign-on.
  url_security_manager_.reset(net::URLSecurityManager::Create(NULL, NULL));

  std::vector<std::string> supported_schemes;
  supported_schemes.push_back("basic");
  supported_schemes.push_back("digest");
  supported_schemes.push_back("ntlm");
  supported_schemes.push_back("negotiate");

  storage_.set_http_auth_handler_factory(
      net::HttpAuthHandlerRegistryFactory::Create(supported_schemes,
                                                  url_security_manager_.get(),
                                                  host_resolver(),
                                                  std::string(),
                                                  false,
                                                  false));
  storage_.set_http_server_properties(new net::HttpServerPropertiesImpl);

  net::HttpCache::DefaultBackend* backend = new net::HttpCache::DefaultBackend(
      cache_path_valid ? net::DISK_CACHE : net::MEMORY_CACHE,
      cache_path, 0, BrowserResourceLoaderBridge::GetCacheThread());

  net::HttpCache* cache =
      new net::HttpCache(host_resolver(), cert_verifier(),
                         origin_bound_cert_service(), NULL, NULL,
                         proxy_service(), ssl_config_service(),
                         http_auth_handler_factory(), NULL,
                         http_server_properties(), NULL, backend);

  cache->set_mode(cache_mode);
  storage_.set_http_transaction_factory(cache);

  storage_.set_ftp_transaction_factory(
      new net::FtpNetworkLayer(host_resolver()));

  blob_storage_controller_.reset(new webkit_blob::BlobStorageController());
  file_system_context_ = static_cast<BrowserFileSystem*>(
      WebKit::webKitPlatformSupport()->fileSystem())->file_system_context();

  net::URLRequestJobFactory* job_factory = new net::URLRequestJobFactory;
  job_factory->SetProtocolHandler(
      "blob",
      new webkit_blob::BlobProtocolHandler(
          blob_storage_controller_.get(),
          CefThread::GetMessageLoopProxyForThread(CefThread::FILE)));
  job_factory->SetProtocolHandler(
      "filesystem",
      fileapi::CreateFileSystemProtocolHandler(
          file_system_context_.get(),
          CefThread::GetMessageLoopProxyForThread(CefThread::FILE)));
  storage_.set_job_factory(job_factory);
}

BrowserRequestContext::~BrowserRequestContext() {
}

void BrowserRequestContext::SetAcceptAllCookies(bool accept_all_cookies) {
  accept_all_cookies_ = accept_all_cookies;
}

bool BrowserRequestContext::AcceptAllCookies() {
  return accept_all_cookies_;
}

const std::string& BrowserRequestContext::GetUserAgent(
    const GURL& url) const {
  return webkit_glue::GetUserAgent(url);
}

