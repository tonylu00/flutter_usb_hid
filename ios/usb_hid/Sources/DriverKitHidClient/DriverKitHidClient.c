#include "DriverKitHidClient.h"

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdlib.h>
#include <string.h>

static const char *const kUsbHidDriverService =
    "DaliMasterEspressifUsbDriver";

enum {
  kUsbHidDriverGetInfo = 0,
  kUsbHidDriverWrite = 1,
  kUsbHidDriverRead = 2,
  kUsbHidDriverControl = 3,
};

typedef struct {
  uint8_t direction;
  uint8_t requestType;
  uint8_t request;
  uint8_t reserved;
  uint16_t value;
  uint16_t index;
  uint32_t length;
} UsbHidControlRequest;

static bool UsbHidDriverGetInfo(io_connect_t connection,
                                UsbHidDriverDeviceInfo *info) {
  size_t outputSize = sizeof(*info);
  memset(info, 0, sizeof(*info));
  kern_return_t result = IOConnectCallStructMethod(
      connection, kUsbHidDriverGetInfo, NULL, 0, info, &outputSize);
  return result == KERN_SUCCESS && outputSize == sizeof(*info) &&
         info->protocolVersion == 1 && info->kind == UsbHidDriverKindHid;
}

size_t UsbHidDriverCopyDevices(UsbHidDriverDeviceInfo *devices,
                               size_t capacity) {
  CFMutableDictionaryRef matching =
      IOServiceNameMatching(kUsbHidDriverService);
  if (matching == NULL) {
    return 0;
  }
  io_iterator_t iterator = IO_OBJECT_NULL;
  kern_return_t result = IOServiceGetMatchingServices(
      kIOMainPortDefault, matching, &iterator);
  if (result != KERN_SUCCESS) {
    return 0;
  }

  size_t count = 0;
  io_service_t service = IO_OBJECT_NULL;
  while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
    io_connect_t connection = IO_OBJECT_NULL;
    UsbHidDriverDeviceInfo info;
    if (IOServiceOpen(service, mach_task_self_, 0, &connection) ==
            KERN_SUCCESS &&
        UsbHidDriverGetInfo(connection, &info)) {
      uint64_t registryEntryId = 0;
      if (IORegistryEntryGetRegistryEntryID(service, &registryEntryId) ==
          KERN_SUCCESS) {
        info.registryEntryId = registryEntryId;
        if (devices != NULL && count < capacity) {
          devices[count] = info;
        }
        count++;
      }
    }
    if (connection != IO_OBJECT_NULL) {
      IOServiceClose(connection);
    }
    IOObjectRelease(service);
  }
  IOObjectRelease(iterator);
  return count;
}

bool UsbHidDriverIsAvailable(void) {
  return UsbHidDriverCopyDevices(NULL, 0) > 0;
}

int32_t UsbHidDriverOpen(uint64_t registryEntryId, uint32_t *connection) {
  if (connection == NULL) {
    return kIOReturnBadArgument;
  }
  *connection = IO_OBJECT_NULL;
  CFMutableDictionaryRef matching =
      IOServiceNameMatching(kUsbHidDriverService);
  if (matching == NULL) {
    return kIOReturnNoMemory;
  }
  io_iterator_t iterator = IO_OBJECT_NULL;
  kern_return_t result = IOServiceGetMatchingServices(
      kIOMainPortDefault, matching, &iterator);
  if (result != KERN_SUCCESS) {
    return result;
  }

  io_service_t service = IO_OBJECT_NULL;
  result = kIOReturnNotFound;
  while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
    uint64_t candidateId = 0;
    if (IORegistryEntryGetRegistryEntryID(service, &candidateId) ==
            KERN_SUCCESS &&
        candidateId == registryEntryId) {
      io_connect_t opened = IO_OBJECT_NULL;
      result = IOServiceOpen(service, mach_task_self_, 0, &opened);
      if (result == KERN_SUCCESS) {
        UsbHidDriverDeviceInfo info;
        if (UsbHidDriverGetInfo(opened, &info)) {
          *connection = opened;
        } else {
          IOServiceClose(opened);
          result = kIOReturnUnsupported;
        }
      }
      IOObjectRelease(service);
      break;
    }
    IOObjectRelease(service);
  }
  IOObjectRelease(iterator);
  return result;
}

void UsbHidDriverClose(uint32_t connection) {
  if (connection != IO_OBJECT_NULL) {
    IOServiceClose((io_connect_t)connection);
  }
}

int32_t UsbHidDriverWrite(uint32_t connection,
                          const uint8_t *bytes,
                          uint32_t length,
                          uint32_t *bytesWritten) {
  if (connection == IO_OBJECT_NULL || bytes == NULL || bytesWritten == NULL) {
    return kIOReturnBadArgument;
  }
  uint64_t output = 0;
  uint32_t outputCount = 1;
  kern_return_t result = IOConnectCallMethod(
      (io_connect_t)connection, kUsbHidDriverWrite, NULL, 0, bytes, length,
      &output, &outputCount, NULL, NULL);
  *bytesWritten = result == KERN_SUCCESS ? (uint32_t)output : 0;
  return result;
}

int32_t UsbHidDriverRead(uint32_t connection,
                         uint8_t *bytes,
                         uint32_t capacity,
                         uint32_t *bytesRead) {
  if (connection == IO_OBJECT_NULL || bytes == NULL || bytesRead == NULL) {
    return kIOReturnBadArgument;
  }
  const uint64_t inputs[] = {capacity, 0};
  size_t outputSize = capacity;
  kern_return_t result = IOConnectCallMethod(
      (io_connect_t)connection, kUsbHidDriverRead, inputs, 2, NULL, 0,
      NULL, NULL, bytes, &outputSize);
  *bytesRead = result == KERN_SUCCESS ? (uint32_t)outputSize : 0;
  return result;
}

static int32_t UsbHidDriverFeatureRequest(uint32_t connection,
                                          bool input,
                                          uint8_t reportId,
                                          const uint8_t *inputBytes,
                                          uint32_t inputLength,
                                          uint8_t *outputBytes,
                                          uint32_t outputCapacity,
                                          uint32_t *bytesRead) {
  const uint32_t payloadLength = input ? 0 : inputLength;
  const size_t requestSize = sizeof(UsbHidControlRequest) + payloadLength;
  uint8_t *requestBytes = (uint8_t *)calloc(1, requestSize);
  if (requestBytes == NULL) {
    return kIOReturnNoMemory;
  }
  UsbHidControlRequest *request = (UsbHidControlRequest *)requestBytes;
  request->direction = input ? 1 : 0;
  request->requestType = 1;
  request->request = input ? 1 : 9;
  request->value = (uint16_t)((3U << 8U) | reportId);
  request->length = input ? outputCapacity : inputLength;
  if (!input && inputLength > 0) {
    memcpy(requestBytes + sizeof(*request), inputBytes, inputLength);
  }

  size_t outputSize = input ? outputCapacity : 0;
  kern_return_t result = IOConnectCallStructMethod(
      (io_connect_t)connection, kUsbHidDriverControl, requestBytes,
      requestSize, outputBytes, &outputSize);
  free(requestBytes);
  if (bytesRead != NULL) {
    *bytesRead = result == KERN_SUCCESS ? (uint32_t)outputSize : 0;
  }
  return result;
}

int32_t UsbHidDriverSetFeature(uint32_t connection,
                               uint8_t reportId,
                               const uint8_t *bytes,
                               uint32_t length) {
  return UsbHidDriverFeatureRequest(connection, false, reportId, bytes,
                                    length, NULL, 0, NULL);
}

int32_t UsbHidDriverGetFeature(uint32_t connection,
                               uint8_t reportId,
                               uint8_t *bytes,
                               uint32_t capacity,
                               uint32_t *bytesRead) {
  return UsbHidDriverFeatureRequest(connection, true, reportId, NULL, 0,
                                    bytes, capacity, bytesRead);
}
