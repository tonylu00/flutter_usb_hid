#include <gtest/gtest.h>

#include "include/usb_hid/usb_hid_plugin.h"
#include "usb_hid_plugin_private.h"

namespace usb_hid {
namespace test {

TEST(UsbHidPlugin, TypeRegistered) {
  EXPECT_NE(usb_hid_plugin_get_type(), 0u);
}

// hidapi reports product/manufacturer/serial strings as wchar_t (UTF-32 on
// Linux); they must not be decoded as UTF-16.
TEST(UsbHidPlugin, WideStringsAreUtf32) {
  EXPECT_EQ(usb_hid_wide_to_utf8(L"DALI USB"), "DALI USB");
  EXPECT_EQ(usb_hid_wide_to_utf8(L"Lammin \u00fc\u2713 \u65e5\U0001F4A1"),
            "Lammin \xc3\xbc\xe2\x9c\x93 \xe6\x97\xa5\xf0\x9f\x92\xa1");
  EXPECT_EQ(usb_hid_wide_to_utf8(nullptr), "");
}

}  // namespace test
}  // namespace usb_hid
