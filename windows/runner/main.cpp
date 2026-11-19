#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// ShareBro's window: the runner's window class with our title.
HWND FindShareBroWindow() {
  return ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"ShareBro");
}

// One ShareBro at a time: opening it again brings the open one to the
// front. Returns true when that happened and this copy should quit. A copy
// whose window never shows (still starting, or stuck) doesn't count: then
// this one starts normally.
bool HandOffToRunningCopy() {
  ::CreateMutexW(nullptr, TRUE, L"Local\\ShareBro.SingleInstance");
  if (::GetLastError() != ERROR_ALREADY_EXISTS) return false;
  // Its window appears once it has drawn; give it a few seconds.
  for (int i = 0; i < 50; i++) {
    HWND existing = FindShareBroWindow();
    if (existing != nullptr && ::IsWindowVisible(existing)) {
      if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
      return true;
    }
    ::Sleep(100);
  }
  return false;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (HandOffToRunningCopy()) {
    return EXIT_SUCCESS;
  }

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
  Win32Window::Size size(1280, 800);
  if (!window.Create(L"ShareBro", origin, size)) {
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
