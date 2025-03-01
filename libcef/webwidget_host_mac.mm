// Copyright (c) 2008-2009 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <Cocoa/Cocoa.h>

#include "webwidget_host.h"

#include "base/logging.h"
#include "skia/ext/platform_canvas.h"
#include "third_party/WebKit/Source/WebKit/chromium/public/mac/WebInputEventFactory.h"
#include "third_party/WebKit/Source/WebKit/chromium/public/mac/WebScreenInfoFactory.h"
#include "third_party/WebKit/Source/WebKit/chromium/public/WebInputEvent.h"
#include "third_party/WebKit/Source/WebKit/chromium/public/WebPopupMenu.h"
#include "third_party/WebKit/Source/WebKit/chromium/public/WebScreenInfo.h"
#include "third_party/WebKit/Source/WebKit/chromium/public/WebSize.h"
#include "ui/gfx/rect.h"
#include "ui/gfx/size.h"
#include "webkit/glue/webkit_glue.h"

using WebKit::WebInputEvent;
using WebKit::WebInputEventFactory;
using WebKit::WebKeyboardEvent;
using WebKit::WebMouseEvent;
using WebKit::WebMouseWheelEvent;
using WebKit::WebPopupMenu;
using WebKit::WebScreenInfo;
using WebKit::WebScreenInfoFactory;
using WebKit::WebSize;
using WebKit::WebWidgetClient;

/*static*/
WebWidgetHost* WebWidgetHost::Create(NSView* parent_view,
                                     WebWidgetClient* client,
                                     PaintDelegate* paint_delegate) {
  WebWidgetHost* host = new WebWidgetHost();

  NSRect client_rect = [parent_view bounds];
  host->view_ = [[NSView alloc] initWithFrame:client_rect];
  [parent_view addSubview:host->view_];

  host->webwidget_ = WebPopupMenu::create(client);
  host->webwidget_->resize(WebSize(NSWidth(client_rect),
                                   NSHeight(client_rect)));
  return host;
}

void WebWidgetHost::DidInvalidateRect(const gfx::Rect& damaged_rect) {
#ifndef NDEBUG
  DLOG_IF(WARNING, painting_) << "unexpected invalidation while painting";
#endif

  const gfx::Rect client_rect(NSRectToCGRect([view_ bounds]));
  paint_rect_ = paint_rect_.Union(damaged_rect);
  paint_rect_ = paint_rect_.Intersect(client_rect);

  if (!paint_rect_.IsEmpty()) {
    // Convert scroll rectangle to the view's coordinate system.
    NSRect r = NSRectFromCGRect(damaged_rect.ToCGRect());
    r.origin.y = NSHeight([view_ frame]) - NSMaxY(r);
    [view_ setNeedsDisplayInRect:r];
  }
}

void WebWidgetHost::DidScrollRect(int dx, int dy, const gfx::Rect& clip_rect) {
  DCHECK(dx || dy);

  const gfx::Rect client_rect(NSRectToCGRect([view_ bounds]));
  gfx::Rect rect = clip_rect.Intersect(client_rect);

  // The scrolling rect must not scroll outside the clip rect, because that will
  // clobber the scrollbars; so the rectangle is shortened a bit from the
  // leading side of the scroll (could be either horizontally or vertically).
  if (dx > 0)
    rect = gfx::Rect(rect.x(), rect.y(), rect.width() - dx, rect.height());
  else if (dx < 0)
    rect = gfx::Rect(rect.x() - dx, rect.y(), rect.width() + dx, rect.height());
  else if (dy > 0)
    rect = gfx::Rect(rect.x(), rect.y(), rect.width(), rect.height() - dy);
  else if (dy < 0)
    rect = gfx::Rect(rect.x(), rect.y() - dy, rect.width(), rect.height() + dy);

  // Convert scroll rectangle to the view's coordinate system, and perform the
  // scroll directly, without invalidating the view. In theory this could cause
  // some kind of performance issue, since we're not coalescing redraw events,
  // but in practice we get much smoother scrolling of big views, since just
  // copying the pixels within the window is much faster than redrawing them.
  NSRect r = NSRectFromCGRect(rect.ToCGRect());
  r.origin.y = NSHeight([view_ bounds]) - NSMaxY(r);
  [view_ scrollRect:r by:NSMakeSize(dx, -dy)];

  const bool can_paint = [view_ lockFocusIfCanDraw];
  const gfx::Rect saved_paint_rect = paint_rect_;
  gfx::Rect dirty_rect_if_cannot_paint = paint_rect_;

  // Repaint the rectangle that was revealed when scrolling the given rectangle.
  // We don't want to invalidate the rectangle, because that would cause the
  // invalidated area to be L-shaped, because of this narrow area, and the
  // scrollbar area that also could be invalidated, and the union of those two
  // rectangles is pretty much the entire view area, and we would not save any
  // work by doing the scrollRect: call above.
  if (dx > 0)
    paint_rect_ = gfx::Rect(rect.x(), rect.y(), dx, rect.height());
  else if (dx < 0)
    paint_rect_ = gfx::Rect(rect.right() + dx, rect.y(), -dx, rect.height());
  else if (dy > 0)
    paint_rect_ = gfx::Rect(rect.x(), rect.y(), rect.width(), dy);
  else if (dy < 0)
    paint_rect_ = gfx::Rect(rect.x(), rect.bottom() + dy, rect.width(), -dy);

  paint_rect_ = paint_rect_.Intersect(client_rect);
  dirty_rect_if_cannot_paint = dirty_rect_if_cannot_paint.Union(paint_rect_);
  if (can_paint && !paint_rect_.IsEmpty())
    Paint();

  // If any part of the scrolled rect was marked as dirty, make sure to redraw
  // it in the new scrolled-to location. Otherwise we can end up with artifacts
  // for overlapping elements.
  gfx::Rect moved_paint_rect = saved_paint_rect.Intersect(clip_rect);
  if (!moved_paint_rect.IsEmpty()) {
    moved_paint_rect.Offset(dx, dy);
    paint_rect_ = moved_paint_rect;
    paint_rect_ = paint_rect_.Intersect(client_rect);
    dirty_rect_if_cannot_paint = dirty_rect_if_cannot_paint.Union(paint_rect_);
    if (can_paint && !paint_rect_.IsEmpty())
      Paint();
  }
  
  paint_rect_ = saved_paint_rect;

  if (can_paint)
    [view_ unlockFocus];
  else 
    DidInvalidateRect(dirty_rect_if_cannot_paint);
}

void WebWidgetHost::ScheduleComposite() {
  if (!webwidget_)
    return;
  WebSize size = webwidget_->size();
  NSRect r = NSMakeRect(0, 0, size.width, size.height);
  [view_ setNeedsDisplayInRect:r];
}

WebWidgetHost::WebWidgetHost()
    : view_(NULL),
      paint_delegate_(NULL),
      webwidget_(NULL),
      canvas_w_(0),
      canvas_h_(0),
      popup_(false),
      has_update_task_(false),
      ALLOW_THIS_IN_INITIALIZER_LIST(weak_factory_(this)) {
  set_painting(false);
}

WebWidgetHost::~WebWidgetHost() {
}

void WebWidgetHost::Paint() {
  gfx::Rect client_rect(NSRectToCGRect([view_ bounds]));
  gfx::Rect update_rect;
  
  if (!webwidget_->isAcceleratedCompositingActive()) {
    // Number of pixels that the canvas is allowed to differ from the client
    // area.
    const int kCanvasGrowSize = 128;

    if (!canvas_.get() ||
        canvas_w_ < client_rect.width() ||
        canvas_h_ < client_rect.height() ||
        canvas_w_ > client_rect.width() + kCanvasGrowSize * 2 ||
        canvas_h_ > client_rect.height() + kCanvasGrowSize * 2) {
      paint_rect_ = client_rect;

      // Resize the canvas to be within a reasonable size of the client area.
      canvas_w_ = client_rect.width() + kCanvasGrowSize;
      canvas_h_ = client_rect.height() + kCanvasGrowSize;
      canvas_.reset(new skia::PlatformCanvas(canvas_w_, canvas_h_, true));
    }
  } else if(!canvas_.get() || canvas_w_ != client_rect.width() ||
            canvas_h_ != client_rect.height()) {
    paint_rect_ = client_rect;

    // The canvas must be the exact size of the client area.
    canvas_w_ = client_rect.width();
    canvas_h_ = client_rect.height();
    canvas_.reset(new skia::PlatformCanvas(canvas_w_, canvas_h_, true));
  }

  // Draw into the graphics context of the canvas instead of the view's context.
  // The view's context is pushed onto the context stack, to be restored below.
  CGContextRef bitmap_context =
      skia::GetBitmapContext(skia::GetTopDevice(*canvas_));
  NSGraphicsContext* paint_context =
      [NSGraphicsContext graphicsContextWithGraphicsPort:bitmap_context
                                                 flipped:YES];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:paint_context];

  webwidget_->animate(0.0);

  // This may result in more invalidation
  webwidget_->layout();

  // Paint the canvas if necessary.  Allow painting to generate extra rects the
  // first time we call it.  This is necessary because some WebCore rendering
  // objects update their layout only when painted.
  for (int i = 0; i < 2; ++i) {
    paint_rect_ = client_rect.Intersect(paint_rect_);
    if (!paint_rect_.IsEmpty()) {
      gfx::Rect rect(paint_rect_);
      update_rect = (i == 0? rect: update_rect.Union(rect));
      paint_rect_ = gfx::Rect();

//    DLOG_IF(WARNING, i == 1) << "painting caused additional invalidations";
      PaintRect(rect);
    }
  }
  DCHECK(paint_rect_.IsEmpty());

  // set the context back to our window
  [NSGraphicsContext restoreGraphicsState];

  // Paint to the screen
  NSGraphicsContext* view_context = [NSGraphicsContext currentContext];
  CGContextRef context = static_cast<CGContextRef>([view_context graphicsPort]);
  CGRect bitmap_rect = { { update_rect.x(), update_rect.y() },
                         { update_rect.width(), update_rect.height() } };
  skia::DrawToNativeContext(canvas_.get(), context, update_rect.x(),
      client_rect.height() - update_rect.bottom(), &bitmap_rect);
}

void WebWidgetHost::SetTooltipText(const CefString& tooltip_text)
{
  // TODO(port): Implement this method as part of tooltip support.
}

void WebWidgetHost::InvalidateRect(const gfx::Rect& rect)
{
  // TODO(port): Implement this method as part of off-screen rendering support.
  NOTIMPLEMENTED();
}

bool WebWidgetHost::GetImage(int width, int height, void* rgba_buffer)
{
  if (!canvas_.get())
    return false;

  // TODO(port): Implement this method as part of off-screen rendering support.
  NOTIMPLEMENTED();
  return false;
}

WebScreenInfo WebWidgetHost::GetScreenInfo() {
  return WebScreenInfoFactory::screenInfo(view_);
}

void WebWidgetHost::Resize(const gfx::Rect& rect) {
  SetSize(rect.width(), rect.height());
}

void WebWidgetHost::MouseEvent(NSEvent *event) {
  const WebMouseEvent& web_event = WebInputEventFactory::mouseEvent(
      event, view_);
  webwidget_->handleInputEvent(web_event);
}

void WebWidgetHost::WheelEvent(NSEvent *event) {
  webwidget_->handleInputEvent(
      WebInputEventFactory::mouseWheelEvent(event, view_));
}

void WebWidgetHost::KeyEvent(NSEvent *event) {
  WebKeyboardEvent keyboard_event(WebInputEventFactory::keyboardEvent(event));
  last_key_event_ = keyboard_event;
  webwidget_->handleInputEvent(keyboard_event);
  if ([event type] == NSKeyDown &&
      !([event modifierFlags] & NSNumericPadKeyMask)) {
    // Send a Char event here to emulate the keyboard events. Do not send a
    // Char event for arrow keys (NSNumericPadKeyMask modifier will be set).
    // TODO(hbono): Bug 20852 <http://crbug.com/20852> implement the
    // NSTextInput protocol and remove this code.
    keyboard_event.type = WebInputEvent::Char;
    last_key_event_ = keyboard_event;
    webwidget_->handleInputEvent(keyboard_event);
  }
}

void WebWidgetHost::SetFocus(bool enable) {
  webwidget_->setFocus(enable);
}

void WebWidgetHost::PaintRect(const gfx::Rect& rect) {
#ifndef NDEBUG
  DCHECK(!painting_);
#endif
  DCHECK(canvas_.get());

  set_painting(true);
  webwidget_->paint(webkit_glue::ToWebCanvas(canvas_.get()), rect);
  set_painting(false);
}

void WebWidgetHost::SendKeyEvent(cef_key_type_t type, int key, int modifiers,
                                 bool sysChar, bool imeChar)
{
  // TODO(port): Implement this method as part of off-screen rendering support.
  NOTIMPLEMENTED();
}

void WebWidgetHost::SendMouseClickEvent(int x, int y,
                                        cef_mouse_button_type_t type,
                                        bool mouseUp, int clickCount)
{
  // TODO(port): Implement this method as part of off-screen rendering support.
  NOTIMPLEMENTED();
}

void WebWidgetHost::SendMouseMoveEvent(int x, int y, bool mouseLeave)
{
  // TODO(port): Implement this method as part of off-screen rendering support.
  NOTIMPLEMENTED();
}

void WebWidgetHost::SendMouseWheelEvent(int x, int y, int delta)
{
  // TODO(port): Implement this method as part of off-screen rendering support.
  NOTIMPLEMENTED();
}

void WebWidgetHost::SendFocusEvent(bool setFocus)
{
  // TODO(port): Implement this method as part of off-screen rendering support.
  NOTIMPLEMENTED();
}

void WebWidgetHost::SendCaptureLostEvent()
{
  // TODO(port): Implement this method as part of off-screen rendering support.
  NOTIMPLEMENTED();
}

void WebWidgetHost::EnsureTooltip()
{
  // TODO(port): Implement this method as part of tooltip support.
}

void WebWidgetHost::ResetTooltip()
{
  // TODO(port): Implement this method as part of tooltip support.
}
