#include <gtest/gtest.h>

#include "include/usb_hid/usb_hid_plugin.h"

namespace usb_hid {
namespace test {

TEST(UsbHidPlugin, TypeRegistered) {
  EXPECT_NE(usb_hid_plugin_get_type(), 0u);
}

}  // namespace test
}  // namespace usb_hid
