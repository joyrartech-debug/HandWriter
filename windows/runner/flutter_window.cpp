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
  const bool tip_in_contact =
      (pen_info.pointerInfo.pointerFlags & POINTER_FLAG_INCONTACT) != 0;
  const bool first_button_pen =
      (pen_info.pointerInfo.pointerFlags & POINTER_FLAG_FIRSTBUTTON) != 0;
  last_pen_pointer_id_ = pointer_id;

  // Diagnostic: forward every meaningful transition with FULL context
  // so we can see, from the log file alone, exactly what a tablet's
  // upper barrel toggles. Includes:
  //   - msg: the WM_POINTER message type (DOWN/UPDATE/UP)
  //   - penFlags: raw PEN_FLAG_* bits
  //   - pointerFlags: raw POINTER_FLAG_* bits (NO masking)
  //   - buttonChange: POINTER_BUTTON_CHANGE_TYPE for this event
  //   - pressure: raw pen pressure (0..1024)
  //   - inputData: wheel/scroll data if any
  // Transition trigger: penFlags OR pointerFlags change. Fires once
  // per real state change, hover noise is negligible.
  if (pen_info.penFlags != last_pen_flags_ ||
      pen_info.pointerInfo.pointerFlags != last_pointer_state_) {
    NotifyPenFlagsChange(pen_info.penFlags,
                         pen_info.pointerInfo.pointerFlags, message,
                         static_cast<uint32_t>(
                             pen_info.pointerInfo.ButtonChangeType),
                         pen_info.pressure,
                         pen_info.pointerInfo.InputData);
    last_pen_flags_ = pen_info.penFlags;
    last_pointer_state_ = pen_info.pointerInfo.pointerFlags;
  }

  // Latch the Gaomon-driverless upper-barrel state. Only LATCH when
  // FIRSTBUTTON transitions from 0→1 with the tip NOT in contact —
  // that combo never happens for a real tip touch (which would also
  // set INCONTACT) so it uniquely identifies the upper barrel on
  // driver setups that don't expose PEN_FLAG_INVERTED. Once latched,
  // we keep the override alive until FIRSTBUTTON drops, even if the
  // user touches the tip mid-gesture (both bits set then).
  if (first_button_pen && !last_first_button_pen_ && !tip_in_contact) {
    upper_button_latched_ = true;
  }
  if (!first_button_pen) {
    upper_button_latched_ = false;
  }
  last_first_button_pen_ = first_button_pen;

  const bool inverted_now =
      ((pen_info.penFlags & PEN_FLAG_INVERTED) != 0) || upper_button_latched_;

  // Compute current logical client coordinates once — used for any
  // pen-gesture phase we forward below.
  POINT pt = pen_info.pointerInfo.ptPixelLocation;
  if (child_hwnd_) ScreenToClient(child_hwnd_, &pt);
  const UINT dpi = child_hwnd_ ? GetDpiForWindow(child_hwnd_) : 96;
  const double dpr = dpi > 0 ? dpi / 96.0 : 1.0;
  const double x_logical = pt.x / dpr;
  const double y_logical = pt.y / dpr;
  const double pressure_norm = pen_info.pressure > 0
      ? static_cast<double>(pen_info.pressure) / 1024.0
      : 0.5;

  // End an active pen gesture FIRST (before announcing the button
  // release) so Dart's _onBarrelPen still has access to the
  // override-target tool when it commits the lasso / eraser stroke.
  const bool button_releasing =
      (last_barrel_pressed_ && !barrel_now) ||
      (last_inverted_ && !inverted_now);
  if (pen_gesture_active_ && (!tip_in_contact || button_releasing)) {
    NotifyBarrelPen("up", x_logical, y_logical, pressure_norm);
    pen_gesture_active_ = false;
  }

  if (barrel_now != last_barrel_pressed_) {
    NotifyBarrelChange("barrel", barrel_now);
    last_barrel_pressed_ = barrel_now;
  }
  if (inverted_now != last_inverted_) {
    NotifyBarrelChange("inverted", inverted_now);
    last_inverted_ = inverted_now;
  }

  // While a side button is held and the tip is in contact, Gaomon
  // driverless never delivers a Flutter PointerEvent — the canvas
  // Listener stays silent and the lasso/eraser never sees the
  // gesture. Synthesise the down/move/up sequence from the raw
  // WM_POINTER stream we already read above; Dart's _onBarrelPen
  // drives the override directly from these.
  const bool any_button_held = last_barrel_pressed_ || last_inverted_;
  if (any_button_held && tip_in_contact) {
    if (!pen_gesture_active_) {
      pen_gesture_active_ = true;
      NotifyBarrelPen("down", x_logical, y_logical, pressure_norm);
    } else {
      NotifyBarrelPen("move", x_logical, y_logical, pressure_norm);
    }
  }

  last_tip_in_contact_ = tip_in_contact;

  // No defensive cleanup on WM_POINTERUP: the previous version
  // force-released the barrel on every tip-lift, which caused a
  // spurious flap (barrel goes false → next hover update sees
  // PEN_FLAG_BARREL still set → fires true again, 5 ms later) and
  // dropped `_activeNativeBarrel` mid-gesture. The actual barrel
  // state is now tracked exclusively through penFlags transitions
  // above. If the pen leaves the digitizer entirely the Dart side
  // simply stays in override-mode until the user returns the pen,
  // at which point a fresh transition restores the correct state.
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

void FlutterWindow::NotifyPenFlagsChange(uint32_t pen_flags,
                                         uint32_t pointer_flags,
                                         uint32_t msg,
                                         uint32_t button_change_type,
                                         uint32_t pressure,
                                         int32_t input_data) {
  if (!pen_channel_) return;
  flutter::EncodableMap args = {
      {flutter::EncodableValue("penFlags"),
       flutter::EncodableValue(static_cast<int64_t>(pen_flags))},
      {flutter::EncodableValue("pointerFlags"),
       flutter::EncodableValue(static_cast<int64_t>(pointer_flags))},
      {flutter::EncodableValue("msg"),
       flutter::EncodableValue(static_cast<int64_t>(msg))},
      {flutter::EncodableValue("buttonChange"),
       flutter::EncodableValue(static_cast<int64_t>(button_change_type))},
      {flutter::EncodableValue("pressure"),
       flutter::EncodableValue(static_cast<int64_t>(pressure))},
      {flutter::EncodableValue("inputData"),
       flutter::EncodableValue(static_cast<int64_t>(input_data))},
  };
  pen_channel_->InvokeMethod(
      "onPenFlagsChange",
      std::make_unique<flutter::EncodableValue>(args));
}

void FlutterWindow::NotifyBarrelPen(const std::string& phase, double x,
                                    double y, double pressure) {
  if (!pen_channel_) return;
  flutter::EncodableMap args = {
      {flutter::EncodableValue("phase"), flutter::EncodableValue(phase)},
      {flutter::EncodableValue("x"), flutter::EncodableValue(x)},
      {flutter::EncodableValue("y"), flutter::EncodableValue(y)},
      {flutter::EncodableValue("pressure"), flutter::EncodableValue(pressure)},
  };
  pen_channel_->InvokeMethod(
      "onBarrelPen",
      std::make_unique<flutter::EncodableValue>(args));
}
