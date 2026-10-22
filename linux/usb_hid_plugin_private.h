#include <flutter_linux/flutter_linux.h>

#include <string>

#include "include/usb_hid/usb_hid_plugin.h"

// This file exposes some plugin internals for unit testing. See
// https://github.com/flutter/flutter/issues/88724 for current limitations
// in the unit-testable API.

// Handles the getPlatformVersion method call.
FlMethodResponse *get_platform_version();

// Converts a hidapi wide string (UTF-32 on Linux) to UTF-8; null gives "".
std::string usb_hid_wide_to_utf8(const wchar_t* input);
