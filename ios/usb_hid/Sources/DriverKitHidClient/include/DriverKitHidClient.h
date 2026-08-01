#ifndef DRIVER_KIT_HID_CLIENT_H
#define DRIVER_KIT_HID_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  UsbHidDriverKindUnknown = 0,
  UsbHidDriverKindSerial = 1,
  UsbHidDriverKindHid = 2,
};

typedef struct {
  uint64_t registryEntryId;
  uint32_t protocolVersion;
  uint32_t kind;
  uint16_t vendorId;
  uint16_t productId;
  uint16_t maxInputPacketSize;
  uint16_t maxOutputPacketSize;
  uint8_t interfaceNumber;
  uint8_t inputEndpoint;
  uint8_t outputEndpoint;
  uint8_t reserved;
} UsbHidDriverDeviceInfo;

bool UsbHidDriverIsAvailable(void);
size_t UsbHidDriverCopyDevices(UsbHidDriverDeviceInfo *devices,
                               size_t capacity);
int32_t UsbHidDriverOpen(uint64_t registryEntryId, uint32_t *connection);
void UsbHidDriverClose(uint32_t connection);
int32_t UsbHidDriverWrite(uint32_t connection,
                          const uint8_t *bytes,
                          uint32_t length,
                          uint32_t *bytesWritten);
int32_t UsbHidDriverRead(uint32_t connection,
                         uint8_t *bytes,
                         uint32_t capacity,
                         uint32_t *bytesRead);
int32_t UsbHidDriverSetFeature(uint32_t connection,
                               uint8_t reportId,
                               const uint8_t *bytes,
                               uint32_t length);
int32_t UsbHidDriverGetFeature(uint32_t connection,
                               uint8_t reportId,
                               uint8_t *bytes,
                               uint32_t capacity,
                               uint32_t *bytesRead);

#ifdef __cplusplus
}
#endif

#endif
