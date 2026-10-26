// hidspy.c — logs every HID write libtransport makes, so the wire protocol can be read directly
// instead of guessed. Build: clang -dynamiclib -o hidspy.dylib hidspy.c
// Run:   DYLD_INSERT_LIBRARIES=/tmp/hidspy.dylib <binary that links libtransport>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include <unistd.h>

typedef struct hid_device_ hid_device;

// Interposition makes dlsym(RTLD_NEXT) unreliable here (the calls come from inside the dylib),
// so resolve the real entry points through an explicit handle on the library itself.
static void *transport_handle(void) {
    static void *h = NULL;
    if (!h) {
        const char *candidates[] = {
            "@rpath/libtransport.dylib",
            "/tmp/spy.app/Contents/Frameworks/libtransport.dylib",
            NULL
        };
        for (int i = 0; candidates[i] && !h; i++) h = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
    }
    return h;
}

static void *real_symbol(const char *name) {
    void *p = NULL;
    void *h = transport_handle();
    if (h) p = dlsym(h, name);
    if (!p) p = dlsym(RTLD_NEXT, name);
    return p;
}

static FILE *log_file(void) {
    static FILE *f = NULL;
    if (!f) f = fopen("/tmp/hidspy.log", "a");
    return f;
}

static void dump(const char *what, const unsigned char *d, size_t n) {
    FILE *f = log_file();
    if (!f) return;
    fprintf(f, "%s len=%zu rpt=%02x cmd=%02x key=%02x :", what, n, d[0], n > 1 ? d[1] : 0, n > 2 ? d[2] : 0);
    size_t limit = n < 32 ? n : 32;
    for (size_t i = 0; i < limit; i++) fprintf(f, " %02x", d[i]);
    fprintf(f, "\n");
    fflush(f);
}

ssize_t hid_write(hid_device *dev, const unsigned char *data, size_t length) {
    static ssize_t (*real)(hid_device *, const unsigned char *, size_t) = NULL;
    if (!real) real = (ssize_t (*)(hid_device *, const unsigned char *, size_t))real_symbol("hid_write");
    dump("write", data, length);
    return real ? real(dev, data, length) : -1;
}

ssize_t hid_send_output_report(hid_device *dev, const unsigned char *data, size_t length) {
    static ssize_t (*real)(hid_device *, const unsigned char *, size_t) = NULL;
    if (!real) real = (ssize_t (*)(hid_device *, const unsigned char *, size_t))real_symbol("hid_send_output_report");
    dump("output", data, length);
    return real ? real(dev, data, length) : -1;
}

ssize_t hid_send_feature_report(hid_device *dev, const unsigned char *data, size_t length) {
    static ssize_t (*real)(hid_device *, const unsigned char *, size_t) = NULL;
    if (!real) real = (ssize_t (*)(hid_device *, const unsigned char *, size_t))real_symbol("hid_send_feature_report");
    dump("feature", data, length);
    return real ? real(dev, data, length) : -1;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *replacee; } interposers[] = {
    { (const void *)hid_write, (const void *)hid_write },
    { (const void *)hid_send_output_report, (const void *)hid_send_output_report },
    { (const void *)hid_send_feature_report, (const void *)hid_send_feature_report },
};
