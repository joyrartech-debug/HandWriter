#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // ── Native pen-button bridge ─────────────────────────────────────
  //
  // Flutter on Windows reads pen events via the legacy mouse path,
  // which strips `penFlags`. Drivers such as Gaomon expose the side
  // barrel buttons via that same WM_POINTER stream — but Flutter
  // sees them as `kind=mouse buttons=0x4`, indistinguishable from a
  // physical middle-click. To preserve OneNote-style "hold-barrel"
  // overrides we subscribe to WM_POINTER* in MessageHandler in
  // parallel with Flutter, read `POINTER_PEN_INFO.penFlags`, and
  // forward state transitions to Dart over a MethodChannel.
  //
  // The native pump only OBSERVES — Flutter still processes the
  // same messages itself, so nothing else regresses.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      pen_channel_;
  bool last_barrel_pressed_ = false;
  bool last_inverted_ = false;
  uint32_t last_pen_pointer_id_ = 0;
  // Tracks an active barrel-driven pen gesture (barrel-held + tip in
  // contact). Drives the down→move→up sequence forwarded to Dart so
  // the canvas can drive the lasso/eraser even though Gaomon
  // driverless suppresses Flutter's PointerEvents while the barrel
  // button is pressed.
  bool last_tip_in_contact_ = false;
  bool pen_gesture_active_ = false;
  // Diagnostic: last seen `penFlags` and the relevant subset of
  // `pointerInfo.pointerFlags` (buttons + INCONTACT + INRANGE).
  // Forwarded on every transition so investigating an off-brand
  // tablet's button mapping (e.g. Gaomon upper barrel without the
  // official driver) only needs the user to press the button and
  // send the log — we see exactly which bit moves.
  uint32_t last_pen_flags_ = 0;
  uint32_t last_pointer_state_ = 0;
  // Upper-barrel latch for Gaomon-class driverless tablets: the
  // upper side button on those drivers sets POINTER_FLAG_FIRSTBUTTON
  // in the pen WM_POINTER stream WITHOUT POINTER_FLAG_INCONTACT (a
  // real tip touch sets both). When we see that combo we latch it
  // here and pretend PEN_FLAG_INVERTED was set, so the existing
  // `inverted` override (eraser) path triggers. The latch survives
  // the user touching the tip mid-gesture (both bits set) and only
  // clears when FIRSTBUTTON drops.
  bool last_first_button_pen_ = false;
  bool upper_button_latched_ = false;
  // HWND of the Flutter view child window we subclass to intercept
  // WM_POINTER*. Pointer events on Windows are delivered to the
  // window UNDER the cursor — that's the Flutter renderer child,
  // NOT the top-level FlutterWindow this class wraps.
  HWND child_hwnd_ = nullptr;

  void HandlePenPointerMessage(UINT message, WPARAM wparam);
  void NotifyBarrelChange(const std::string& button, bool down);
  void NotifyBarrelPen(const std::string& phase, double x, double y,
                       double pressure);
  void NotifyPenFlagsChange(uint32_t pen_flags, uint32_t pointer_flags,
                            uint32_t msg, uint32_t button_change_type,
                            uint32_t pressure, int32_t input_data);

  static LRESULT CALLBACK ChildSubclassProc(HWND hwnd, UINT msg,
                                            WPARAM wparam, LPARAM lparam,
                                            UINT_PTR subclass_id,
                                            DWORD_PTR ref_data);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
