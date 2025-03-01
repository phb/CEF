// Copyright (c) 2011 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.
//
// ---------------------------------------------------------------------------
//
// A portion of this file was generated by the CEF translator tool.  When
// making changes by hand only do so within the body of existing function
// implementations. See the translator.README.txt file in the tools directory
// for more information.
//

#include "libcef_dll/cpptoc/scheme_handler_cpptoc.h"
#include "libcef_dll/cpptoc/scheme_handler_factory_cpptoc.h"
#include "libcef_dll/ctocpp/browser_ctocpp.h"
#include "libcef_dll/ctocpp/request_ctocpp.h"


// MEMBER FUNCTIONS - Body may be edited by hand.

struct _cef_scheme_handler_t* CEF_CALLBACK scheme_handler_factory_create(
    struct _cef_scheme_handler_factory_t* self, cef_browser_t* browser,
    const cef_string_t* scheme_name, cef_request_t* request)
{
  CefRefPtr<CefBrowser> browserPtr;
  if (browser)
    browserPtr = CefBrowserCToCpp::Wrap(browser);

  CefRefPtr<CefSchemeHandler> rv =
      CefSchemeHandlerFactoryCppToC::Get(self)->Create(browserPtr,
          CefString(scheme_name), CefRequestCToCpp::Wrap(request));
  if (rv.get())
    return CefSchemeHandlerCppToC::Wrap(rv);

  return NULL;
}


// CONSTRUCTOR - Do not edit by hand.

CefSchemeHandlerFactoryCppToC::CefSchemeHandlerFactoryCppToC(
    CefSchemeHandlerFactory* cls)
    : CefCppToC<CefSchemeHandlerFactoryCppToC, CefSchemeHandlerFactory,
        cef_scheme_handler_factory_t>(cls)
{
  struct_.struct_.create = scheme_handler_factory_create;
}

#ifndef NDEBUG
template<> long CefCppToC<CefSchemeHandlerFactoryCppToC,
    CefSchemeHandlerFactory, cef_scheme_handler_factory_t>::DebugObjCt = 0;
#endif

