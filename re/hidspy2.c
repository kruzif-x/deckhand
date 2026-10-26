// hidspy2.c — logs every IOHIDDeviceSetReport, i.e. the exact byte stream that reaches the panel.
// Interposing hid_write inside libtransport cannot work (its calls are internal, not bound through
// the symbol table); every write does leave the dylib through IOKit, so hook there.
//
//   clang -dynamiclib -framework IOKit -o hidspy2.dylib hidspy2.c
//   DYLD_INSERT_LIBRARIES=/path/hidspy2.dylib /path/Deckhand.app/Contents/MacOS/Deckhand --cli …
#include <stdio.h>
#include <stdint.h>
#include <dlfcn.h>
#include <IOKit/hid/IOHIDLib.h>

typedef IOReturn (*SetReportFn)(IOHIDDeviceRef, IOHIDReportType, CFIndex, const uint8_t *, CFIndex);
typedef IOReturn (*GetReportFn)(IOHIDDeviceRef, IOHIDReportType, CFIndex, uint8_t *, CFIndex *);

static SetReportFn real_set = NULL;
static void resolve(void);
static GetReportFn real_get = NULL;

static FILE *log_file(void) {
    static FILE *f = NULL;
    if (!f) f = fopen("/tmp/hidspy.log", "a");
    return f;
}

__attribute__((constructor))
static void boot_log(void) {
    resolve();
    FILE *f = log_file();
    if (f) {
        fprintf(f, "boot: self_set=%p real_set=%p self_get=%p real_get=%p\n",
                (void *)IOHIDDeviceSetReport, (void *)real_set,
                (void *)IOHIDDeviceGetReport, (void *)real_get);
        fflush(f);
    }
}

static void resolve(void) {
    if (real_set) return;
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
    if (h) {
        real_set = (SetReportFn)dlsym(h, "IOHIDDeviceSetReport");
        real_get = (GetReportFn)dlsym(h, "IOHIDDeviceGetReport");
    }
    if (!real_set) real_set = (SetReportFn)dlsym(RTLD_NEXT, "IOHIDDeviceSetReport");
}

IOReturn IOHIDDeviceSetReport(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID,
                              const uint8_t *report, CFIndex reportLength) {
    resolve();
    FILE *f = log_file();
    if (f) {
        fprintf(f, "set type=%d id=%02lx len=%ld :", (int)type, (long)reportID, (long)reportLength);
        for (CFIndex i = 0; i < (reportLength < 32 ? reportLength : 32); i++) fprintf(f, " %02x", report[i]);
        fprintf(f, "\n");
        fflush(f);
    }
    return real_set ? real_set(device, type, reportID, report, reportLength) : kIOReturnError;
}

IOReturn IOHIDDeviceGetReport(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID,
                              uint8_t *report, CFIndex *reportLength) {
    resolve();
    IOReturn r = real_get ? real_get(device, type, reportID, report, reportLength) : kIOReturnError;
    FILE *f = log_file();
    if (f) {
        fprintf(f, "get type=%d id=%02lx len=%ld ret=%d :", (int)type, (long)reportID,
                reportLength ? (long)*reportLength : -1, (int)r);
        for (CFIndex i = 0; reportLength && i < (*reportLength < 16 ? *reportLength : 16); i++)
            fprintf(f, " %02x", report[i]);
        fprintf(f, "\n");
        fflush(f);
    }
    return r;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *replacee; } interposers[] = {
    { (const void *)IOHIDDeviceSetReport, (const void *)IOHIDDeviceSetReport },
    { (const void *)IOHIDDeviceGetReport, (const void *)IOHIDDeviceGetReport },
};
