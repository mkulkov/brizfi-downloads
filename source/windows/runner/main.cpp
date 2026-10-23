#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <flutter_windows.h>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // Start with the same compact proportions as the mobile screen. Keep the
  // complete window inside the monitor's work area, including at high DPI.
  const POINT point{10, 10};
  const HMONITOR monitor = MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{sizeof(MONITORINFO)};
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  unsigned int width = 480;
  unsigned int height = 820;
  if (GetMonitorInfo(monitor, &info) && scale > 0) {
    width = std::min(width, static_cast<unsigned int>(
        std::max(1.0, (info.rcWork.right - info.rcWork.left - 20) / scale)));
    height = std::min(height, static_cast<unsigned int>(
        std::max(1.0, (info.rcWork.bottom - info.rcWork.top - 20) / scale)));
  }
  Win32Window::Size size(width, height);
  if (!window.Create(L"BRIZFI", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
