#ifndef RUNNER_NATIVE_CHANNELS_H_
#define RUNNER_NATIVE_CHANNELS_H_

#include <flutter/binary_messenger.h>
#include <windows.h>
#include <memory>

// App-owned imports and Windows USB reader transports (WPD and mass storage). All native I/O runs
// on workers; channel replies are drained by the window's platform thread.
class NativeChannels {
 public:
  NativeChannels(HWND window, flutter::BinaryMessenger* messenger);
  ~NativeChannels();
  bool HandleMessage(UINT message);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};
#endif
