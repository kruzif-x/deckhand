// harness.c — drives the vendor transport directly so the interposer can log the exact reports it
// sends. Used only to recover/verify the protocol; not part of the app.
//
//   clang -o harness harness.c
//   DYLD_INSERT_LIBRARIES=./hidspy2.dylib ./harness <jpeg> <hardwareKey>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void *(*enum_fn)(unsigned short, unsigned short);
typedef void (*free_fn)(void *);
typedef int (*create_fn)(void *, void *);
typedef int (*report_fn)(void *, unsigned int, unsigned int, unsigned int);
typedef int (*image_fn)(void *, const unsigned char *, unsigned long, unsigned char);
typedef int (*simple_fn)(void *);

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: harness <jpeg> <key>\n"); return 2; }

    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("jpeg"); return 2; }
    fseek(f, 0, SEEK_END); long size = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *data = malloc(size);
    fread(data, 1, size, f);
    fclose(f);
    unsigned char key = (unsigned char)atoi(argv[2]);

    void *lib = dlopen("../device/sdk/src/StreamDock/Transport/TransportDLL/libtransport.dylib", RTLD_NOW);
    if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }

    enum_fn enumerate = (enum_fn)dlsym(lib, "transport_hid_enumerate");
    free_fn freeEnum = (free_fn)dlsym(lib, "transport_hid_free_enumeration");
    create_fn create = (create_fn)dlsym(lib, "transport_create");
    report_fn setReport = (report_fn)dlsym(lib, "transport_set_reportSize");
    image_fn setImage = (image_fn)dlsym(lib, "transport_set_key_image_stream");
    simple_fn wake = (simple_fn)dlsym(lib, "transport_wakeup_screen");
    simple_fn heartbeat = (simple_fn)dlsym(lib, "transport_heartbeat");
    if (!enumerate || !create || !setImage) { fprintf(stderr, "missing symbols\n"); return 1; }

    void *info = enumerate(0x5548, 0x6674);
    if (!info) { fprintf(stderr, "device not found\n"); return 1; }

    void *handle = NULL;
    int rc = create(info, &handle);
    if (freeEnum) freeEnum(info);
    if (rc != 0 || !handle) { fprintf(stderr, "transport_create rc=%d\n", rc); return 1; }

    if (setReport) printf("set_reportSize rc=%d\n", setReport(handle, 513, 513, 0));
    usleep(200000);
    if (wake) printf("wake rc=%d\n", wake(handle));
    usleep(100000);
    printf("image rc=%d (%ld bytes, key %d)\n", setImage(handle, data, size, key), size, key);
    usleep(600000);
    if (heartbeat) printf("heartbeat rc=%d\n", heartbeat(handle));
    usleep(300000);
    free(data);
    return 0;
}
