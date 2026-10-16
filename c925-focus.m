// c925-focus — Logitech C925e autofocus control for macOS.
//
// "on" and "off" use AVFoundation, as in the original working version.
// "status" attempts an actual read-only USB Video Class Focus Auto GET_CUR.
// It never guesses from AVFoundation state or from previous commands.
//
// Build on a Mac with Command Line Tools:
// xcrun clang -fobjc-arc -Wall -Wextra -framework Foundation \
//   -framework AVFoundation -framework IOKit -framework CoreFoundation \
//   c925-focus.m -o c925-focus

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOKit/usb/USB.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define LOGITECH_VID 0x046d
#define C925E_PID     0x085b
#define UVC_GET_CUR   0x81
#define CT_FOCUS_AUTO 0x08

// Inspect the first configuration descriptor. USB VideoControl's camera
// input terminal advertises Focus Auto in bit 17 of its bmControls bitmap.
// We discover the terminal ID and interface number; neither is hard-coded.
static BOOL findFocusControl(IOUSBDeviceInterface500 **dev,
                             uint8_t *vcInterface, uint8_t *cameraTerminal,
                             const char **reason) {
    IOUSBConfigurationDescriptorPtr cfg = NULL;
    IOReturn kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfg);
    if (kr != kIOReturnSuccess || cfg == NULL) {
        *reason = "cannot read USB configuration descriptor";
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)cfg;
    size_t total = USBToHostWord(cfg->wTotalLength);
    size_t pos = 0;
    BOOL inVideoControl = NO;
    BOOL sawVideoControl = NO;

    while (pos + 2 <= total) {
        size_t len = bytes[pos];
        uint8_t type = bytes[pos + 1];
        if (len < 2 || len > total - pos) break;

        if (type == 0x04 && len >= 9) { // Standard INTERFACE descriptor
            inVideoControl = (bytes[pos + 5] == 0x0e &&
                              bytes[pos + 6] == 0x01);
            if (inVideoControl) {
                *vcInterface = bytes[pos + 2];
                sawVideoControl = YES;
            }
        } else if (inVideoControl && type == 0x24 && len >= 15 &&
                   bytes[pos + 2] == 0x02) { // CS_INTERFACE / INPUT_TERMINAL
            uint16_t terminalType = (uint16_t)bytes[pos + 4] |
                                    ((uint16_t)bytes[pos + 5] << 8);
            if (terminalType == 0x0201) { // Camera input terminal
                uint8_t controlBytes = bytes[pos + 14];
                if (controlBytes < 3 || len < (size_t)15 + controlBytes) {
                    *reason = "camera terminal has no Focus Auto control";
                    return NO;
                }
                // Focus Auto = control bitmap bit 17 = bit 1 of byte 2.
                if ((bytes[pos + 15 + 2] & 0x02) == 0) {
                    *reason = "webcam does not advertise UVC Focus Auto";
                    return NO;
                }
                *cameraTerminal = bytes[pos + 3];
                return YES;
            }
        }
        pos += len;
    }
    *reason = sawVideoControl ? "camera terminal not found in UVC descriptors"
                              : "USB VideoControl interface not found";
    return NO;
}

// Hardware readback. A successful GET_CUR returns 0 = off, 1 = on.
// Do not use USBDeviceOpenSeize: taking control away from the macOS camera
// driver merely to read status could interrupt the camera or other apps.
static int readHardwareFocusStatus(void) {
    const char *classes[] = {"IOUSBHostDevice", "IOUSBDevice"};
    BOOL matched = NO;

    for (size_t ci = 0; ci < sizeof(classes) / sizeof(classes[0]); ++ci) {
        io_iterator_t iterator = IO_OBJECT_NULL;
        kern_return_t result = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching(classes[ci]), &iterator);
        if (result != KERN_SUCCESS) continue;

        io_service_t service;
        while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
            IOCFPlugInInterface **plugin = NULL;
            SInt32 score = 0;
            IOReturn kr = IOCreatePlugInInterfaceForService(
                service, kIOUSBDeviceUserClientTypeID,
                kIOCFPlugInInterfaceID, &plugin, &score);
            IOObjectRelease(service);
            if (kr != kIOReturnSuccess || plugin == NULL) continue;

            IOUSBDeviceInterface500 **dev = NULL;
            HRESULT hr = (*plugin)->QueryInterface(
                plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500),
                (LPVOID *)&dev);
            IODestroyPlugInInterface(plugin);
            if (hr != 0 || dev == NULL) continue;

            UInt16 vid = 0, pid = 0;
            (*dev)->GetDeviceVendor(dev, &vid);
            (*dev)->GetDeviceProduct(dev, &pid);
            if (vid != LOGITECH_VID || pid != C925E_PID) {
                (*dev)->Release(dev);
                continue;
            }

            matched = YES;
            uint8_t interfaceNumber = 0, terminalID = 0;
            const char *reason = NULL;
            if (!findFocusControl(dev, &interfaceNumber, &terminalID, &reason)) {
                fprintf(stderr, "status: unknown (%s).\n", reason);
                (*dev)->Release(dev);
                IOObjectRelease(iterator);
                return 3;
            }

            // Open only the USB device, not the video-streaming interface.
            kr = (*dev)->USBDeviceOpen(dev);
            if (kr != kIOReturnSuccess) {
                fprintf(stderr, "status: unknown (USB device busy or access denied: 0x%08x).\n",
                        (unsigned int)kr);
                (*dev)->Release(dev);
                IOObjectRelease(iterator);
                return 3;
            }

            uint8_t focusAuto = 0xff;
            IOUSBDevRequestTO req = {0};
            req.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBClass, kUSBInterface);
            req.bRequest = UVC_GET_CUR;
            req.wValue = (uint16_t)(CT_FOCUS_AUTO << 8);
            req.wIndex = (uint16_t)((terminalID << 8) | interfaceNumber);
            req.wLength = 1;
            req.pData = &focusAuto;
            req.noDataTimeout = 1000;
            req.completionTimeout = 1000;
            kr = (*dev)->DeviceRequestTO(dev, &req);
            (*dev)->USBDeviceClose(dev);
            (*dev)->Release(dev);
            IOObjectRelease(iterator);

            if (kr != kIOReturnSuccess || req.wLenDone != 1) {
                fprintf(stderr, "status: unknown (UVC GET_CUR failed: 0x%08x).\n",
                        (unsigned int)kr);
                return 3;
            }
            if (focusAuto == 0) {
                puts("off");
                return 0;
            }
            if (focusAuto == 1) {
                puts("on");
                return 0;
            }
            fprintf(stderr, "status: unknown (unexpected UVC value: %u).\n",
                    (unsigned int)focusAuto);
            return 3;
        }
        IOObjectRelease(iterator);
    }
    fprintf(stderr, "status: unknown (%s).\n",
            matched ? "USB status could not be read" : "Logitech C925e USB device not found");
    return 3;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 || (strcmp(argv[1], "on") != 0 &&
                          strcmp(argv[1], "off") != 0 &&
                          strcmp(argv[1], "status") != 0)) {
            fprintf(stderr, "Usage: c925-focus on|off|status\n");
            return 2;
        }

        // Read the hardware itself, rather than AVFoundation's focusMode.
        if (strcmp(argv[1], "status") == 0) {
            return readHardwareFocusStatus();
        }

        // Preserve the known-working AVFoundation on/off implementation.
        AVCaptureDeviceDiscoverySession *session =
            [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal]
                mediaType:AVMediaTypeVideo
                position:AVCaptureDevicePositionUnspecified];

        AVCaptureDevice *camera = nil;
        for (AVCaptureDevice *device in session.devices) {
            if ([device.localizedName containsString:@"C925e"]) {
                camera = device;
                break;
            }
        }
        if (!camera) {
            fprintf(stderr, "Logitech C925e not found.\n");
            return 1;
        }

        AVCaptureFocusMode requestedMode = strcmp(argv[1], "on") == 0
            ? AVCaptureFocusModeContinuousAutoFocus
            : AVCaptureFocusModeLocked;
        if (![camera isFocusModeSupported:requestedMode]) {
            fprintf(stderr, "Requested focus mode is not supported.\n");
            return 3;
        }
        NSError *error = nil;
        if (![camera lockForConfiguration:&error]) {
            fprintf(stderr, "Configuration error: %s\n",
                    error.localizedDescription.UTF8String);
            return 4;
        }
        camera.focusMode = requestedMode;
        [camera unlockForConfiguration];
        puts(strcmp(argv[1], "on") == 0 ? "on" : "off");
        return 0;
    }
}
