#include <jni.h>
#include <errno.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>

// Synchronous only. The worker owns the connection and closes it after this call.
// 0 healthy, 1 retryable EP0 failure, 2 recovered, -1 failure, -2 busy.
static int check_device(int fd) {
    unsigned char bytes[18] = {0};
    struct usbdevfs_ctrltransfer request = {
        .bRequestType = 0x80, .bRequest = 6, .wValue = 0x100,
        .wIndex = 0, .wLength = 18, .timeout = 1500, .data = bytes
    };
    int count = ioctl(fd, USBDEVFS_CONTROL, &request);
    if (count < 0) return errno == EPROTO || errno == ETIMEDOUT ? 1 : -1;
    if (count != 18 || bytes[0] != 18 || bytes[1] != 1 ||
        bytes[8] != 0x49 || bytes[9] != 0x19 ||
        bytes[10] != 0x81 || bytes[11] != 0x99) return -1;
    request.bRequest = 8;
    request.wValue = 0;
    request.wLength = 1;
    bytes[0] = 0;
    count = ioctl(fd, USBDEVFS_CONTROL, &request);
    if (count < 0) return errno == EPROTO || errno == ETIMEDOUT ? 1 : -1;
    return count == 1 && bytes[0] == 1 ? 0 : -1;
}

JNIEXPORT jint JNICALL Java_ru_mkulkov_brizfi_UsbRecovery_nativeCheck(
    JNIEnv *env, jobject receiver, jint fd, jboolean reset) {
    (void)env;
    (void)receiver;
    uint32_t mask = 1;
    unsigned int interface_id = 0;
    if (ioctl(fd, USBDEVFS_DROP_PRIVILEGES, &mask) < 0) return -1;
    if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &interface_id) < 0)
        return errno == EBUSY ? -2 : -1;
    if (!reset) return check_device(fd);
    // Kotlin calls this branch only after status 1 and a cancellation check,
    // on the same still-claimed connection. Do not add another blocking probe.
    // No MTP session/file commands exist yet. Never disconnect a foreign driver.
    if (ioctl(fd, USBDEVFS_RESET, 0) < 0) return -1;
    return check_device(fd) == 0 ? 2 : -1;
}
