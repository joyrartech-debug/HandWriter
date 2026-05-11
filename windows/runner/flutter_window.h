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

  void HandlePenPointerMessage(UINT message, WPARAM wparam);
  void NotifyBarrelChange(const std::string& button, bool down);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
