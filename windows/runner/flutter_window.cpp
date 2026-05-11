#include "flutter_window.h"

#include <commctrl.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

#pragma comment(lib, "comctl32.lib")

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  // NOTE: we deliberately do NOT call EnableMouseInPointer(TRUE)
  // here. Flutter's Windows runner reads MOUSE input from the
  // legacy WM_LBUTTONDOWN / WM_MOUSEMOVE messages, and forcing
  // mouse-in-pointer routes them through WM_POINTER instead —
  // Flutter then loses every click and the window appears frozen.
  // Pen events still arrive via WM_POINTER on Win10+ without the
  // opt-in (pens are pointer-aware by default on the OS side).

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  child_hwnd_ = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(child_hwnd_);

  // Pen-button bridge — see header. Mounted once the engine is alive so
  // the MethodChannel has a valid messenger; nothing is sent until the
  // first WM_POINTER* with a pen pointer type arrives.
  pen_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "handwriter/pen_input",
          &flutter::StandardMethodCodec::GetInstance());

  // Pointer messages are routed to the window UNDER the cursor — on
  // Flutter Windows that's the renderer CHILD HWND, not the
  // top-level FlutterWindow we subclass below. Hook a WindowProc
  // subclass on the child so HandlePenPointerMessage actually sees
  // WM_POINTER* from the digitizer.
  if (child_hwnd_) {
    SetWindowSubclass(child_hwnd_, &FlutterWindow::ChildSubclassProc,
                      /*subclass_id=*/1,
                      reinterpret_cast<DWORD_PTR>(this));
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (child_hwnd_) {
    RemoveWindowSubclass(child_hwnd_, &FlutterWindow::ChildSubclassProc, 1);
    child_hwnd_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

// static
LRESULT CALLBACK FlutterWindow::ChildSubclassProc(HWND hwnd, UINT msg,
                                                  WPARAM wparam,
                                                  LPARAM lparam,
                                                  UINT_PTR /*subclass_id*/,
                                                  DWORD_PTR ref_data) {
  auto* self = reinterpret_cast<FlutterWindow*>(ref_data);
  if (self) {
    switch (msg) {
      case WM_POINTERDOWN:
      case WM_POINTERUPDATE:
      case WM_POINTERUP:
        self->HandlePenPointerMessage(msg, wparam);
        break;
      default:
        break;
    }
  }
  return DefSubclassProc(hwnd, msg, wparam, lparam);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::HandlePenPointerMessage(UINT message, WPARAM wparam) {
  if (!pen_channel_) return;

  const UINT32 pointer_id = GET_POINTERID_WPARAM(wparam);
  POINTER_INPUT_TYPE pointer_type = PT_POINTER;
  if (!GetPointerType(pointer_id, &pointer_type)) return;
  if (pointer_type != PT_PEN) return;

  POINTER_PEN_INFO pen_info{};
  if (!GetPointerPenInfo(pointer_id, &pen_info)) return;

  // PEN_FLAG_BARREL is the lower side button. Gaomon (and most
  // Huion-class tablets) report the upper button by flipping
  // PEN_FLAG_INVERTED — same flag the OS would set if the user
  // flipped the pen to use the eraser end. Both are emitted in the
  // standard WM_POINTERUPDATE stream, even when the pen is just
  // hovering (no tip contact) over the window.
  const bool barrel_now = (pen_info.penFlags & PEN_FLAG_BARREL) != 0;
  const bool inverted_now = (pen_info.penFlags & PEN_FLAG_INVERTED) != 0;
  last_pen_pointer_id_ = pointer_id;

  if (barrel_now != last_barrel_pressed_) {
    NotifyBarrelChange("barrel", barrel_now);
    last_barrel_pressed_ = barrel_now;
  }
  if (inverted_now != last_inverted_) {
    NotifyBarrelChange("inverted", inverted_now);
    last_inverted_ = inverted_now;
  }

  // Defensive: if the pen leaves the digitizer altogether, Windows
  // emits WM_POINTERUP without a corresponding state-change flag, so
  // we force-release any held buttons here so the Dart side never
  // sits stuck in barrel-override mode after the pen lifts out of
  // range.
  if (message == WM_POINTERUP) {
    if (last_barrel_pressed_) {
      NotifyBarrelChange("barrel", false);
      last_barrel_pressed_ = false;
    }
    if (last_inverted_) {
      NotifyBarrelChange("inverted", false);
      last_inverted_ = false;
    }
  }
}

void FlutterWindow::NotifyBarrelChange(const std::string& button, bool down) {
  if (!pen_channel_) return;
  flutter::EncodableMap args = {
      {flutter::EncodableValue("button"), flutter::EncodableValue(button)},
      {flutter::EncodableValue("down"), flutter::EncodableValue(down)},
  };
  pen_channel_->InvokeMethod(
      "onBarrelChange",
      std::make_unique<flutter::EncodableValue>(args));
}
