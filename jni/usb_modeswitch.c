#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>

/* aarch64 Linux usbdevice_fs request codes. Pointers are 8 bytes. */
#define USBDEVFS_CONTROL 0xc0185500u
#define USBDEVFS_BULK 0xc0185502u
#define USBDEVFS_SETCONFIGURATION 0x80045505u
#define USBDEVFS_CLAIMINTERFACE 0x8004550fu
#define USBDEVFS_IOCTL 0xc0105512u
#define USBDEVFS_DISCONNECT 0x00005516u
#define USBDEVFS_DISCONNECT_CLAIM 0x8108551bu

struct usbdevfs_ctrltransfer {
    uint8_t bRequestType;
    uint8_t bRequest;
    uint16_t wValue;
    uint16_t wIndex;
    uint16_t wLength;
    uint32_t timeout;
    uint32_t pad;
    uint64_t data;
};

struct usbdevfs_bulktransfer {
    uint32_t ep;
    uint32_t len;
    uint32_t timeout;
    uint32_t pad;
    uint64_t data;
};

struct usbdevfs_ioctl_wrap {
    int32_t ifno;
    int32_t ioctl_code;
    uint64_t data;
};

struct usbdevfs_disconnect_claim {
    uint32_t interface;
    uint32_t flags;
    char driver[256];
};

#if defined(__aarch64__) || defined(__x86_64__)
_Static_assert(sizeof(struct usbdevfs_ctrltransfer) == 24, "ctrl size");
_Static_assert(sizeof(struct usbdevfs_bulktransfer) == 24, "bulk size");
_Static_assert(sizeof(struct usbdevfs_ioctl_wrap) == 16, "ioctl size");
_Static_assert(sizeof(struct usbdevfs_disconnect_claim) == 264, "disconnect-claim size");
#endif

static int hex_nibble(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int parse_hex(const char *text, uint8_t *out, int cap) {
    int n = 0;
    while (*text) {
        int hi, lo;
        if (*text == ' ' || *text == ':' || *text == '\n') {
            text++;
            continue;
        }
        hi = hex_nibble(*text++);
        if (hi < 0 || *text == '\0') return -1;
        lo = hex_nibble(*text++);
        if (lo < 0 || n >= cap) return -1;
        out[n++] = (uint8_t)((hi << 4) | lo);
    }
    return n;
}

static int ctrl(int fd, uint8_t type, uint8_t req, uint16_t value, uint16_t index,
                 void *data, uint16_t len) {
    struct usbdevfs_ctrltransfer c;
    memset(&c, 0, sizeof c);
    c.bRequestType = type;
    c.bRequest = req;
    c.wValue = value;
    c.wIndex = index;
    c.wLength = len;
    c.timeout = 1000;
    c.data = (uint64_t)(uintptr_t)data;
    return ioctl(fd, USBDEVFS_CONTROL, &c);
}

static int find_bulk(const uint8_t *buf, int len, int *ifnum, int *ep_out, int *ep_in) {
    int i = 0;
    int cur_if = -1;
    int cur_class = -1;
    int found = 0;
    int fb_if = -1;
    int fb_out = -1;
    int fb_in = 0;

    *ep_in = 0;
    while (i + 1 < len) {
        int dlen = buf[i];
        int dtype;
        if (dlen < 2 || i + dlen > len) break;
        dtype = buf[i + 1];
        if (dtype == 4 && dlen >= 9) {
            cur_if = buf[i + 2];
            cur_class = buf[i + 5];
        } else if (dtype == 5 && dlen >= 7 && cur_if >= 0 && (buf[i + 3] & 3) == 2) {
            int addr = buf[i + 2];
            int out = (addr & 0x80) == 0;
            if (cur_class == 8) {
                if (out && !found) {
                    *ifnum = cur_if;
                    *ep_out = addr;
                    found = 1;
                } else if (!out && found && *ifnum == cur_if && *ep_in == 0) {
                    *ep_in = addr;
                }
            }
            if (fb_out < 0 && out) {
                fb_if = cur_if;
                fb_out = addr;
            } else if (!out && fb_if == cur_if && fb_in == 0) {
                fb_in = addr;
            }
        }
        i += dlen;
    }
    if (!found && fb_out >= 0) {
        *ifnum = fb_if;
        *ep_out = fb_out;
        *ep_in = fb_in;
        found = 1;
    }
    return found ? 0 : -1;
}

static int read_config(int fd, uint8_t *buf, int cap) {
    int rc = ctrl(fd, 0x80, 0x06, 0x0200, 0, buf, 9);
    int total;
    if (rc < 9) return -1;
    total = buf[2] | (buf[3] << 8);
    if (total < 9) return -1;
    if (total > cap) total = cap;
    rc = ctrl(fd, 0x80, 0x06, 0x0200, 0, buf, (uint16_t)total);
    return rc < 9 ? -1 : rc;
}

static void claim(int fd, int ifnum) {
    struct usbdevfs_disconnect_claim dc;
    struct usbdevfs_ioctl_wrap io;
    unsigned int ifn = (unsigned int)ifnum;

    memset(&dc, 0, sizeof dc);
    dc.interface = (uint32_t)ifnum;
    if (ioctl(fd, USBDEVFS_DISCONNECT_CLAIM, &dc) == 0) return;

    memset(&io, 0, sizeof io);
    io.ifno = ifnum;
    io.ioctl_code = (int32_t)USBDEVFS_DISCONNECT;
    ioctl(fd, USBDEVFS_IOCTL, &io);
    ioctl(fd, USBDEVFS_CLAIMINTERFACE, &ifn);
}

static int send_cbw(int fd, int ep_out, int ep_in, const uint8_t *msg, int len) {
    struct usbdevfs_bulktransfer b;
    uint8_t csw[13];
    int rc;

    memset(&b, 0, sizeof b);
    b.ep = (uint32_t)ep_out;
    b.len = (uint32_t)len;
    b.timeout = 2000;
    b.data = (uint64_t)(uintptr_t)msg;
    rc = ioctl(fd, USBDEVFS_BULK, &b);
    if (rc < 0) {
        fprintf(stderr, "bulk out ep 0x%02x: %s\n", ep_out, strerror(errno));
        return -1;
    }
    if (ep_in) {
        memset(&b, 0, sizeof b);
        memset(csw, 0, sizeof csw);
        b.ep = (uint32_t)ep_in;
        b.len = sizeof csw;
        b.timeout = 500;
        b.data = (uint64_t)(uintptr_t)csw;
        ioctl(fd, USBDEVFS_BULK, &b);
    }
    return 0;
}

static int open_busdev(int bus, int dev) {
    char path[64];
    int fd;
    snprintf(path, sizeof path, "/dev/bus/usb/%03d/%03d", bus, dev);
    fd = open(path, O_RDWR);
    if (fd < 0) fprintf(stderr, "open %s: %s\n", path, strerror(errno));
    return fd;
}

static void usage(void) {
    fprintf(stderr,
            "usage: usb_modeswitch -b bus -g dev -M hexmessage\n"
            "       sends a 31-byte USB mass-storage CBW (Huawei HiLink switch)\n");
}

int main(int argc, char **argv) {
    int bus = -1;
    int dev = -1;
    const char *hex = NULL;
    uint8_t msg[32];
    uint8_t desc[4096];
    int fd, n, ifnum = 0, ep_out = 0, ep_in = 0, dlen, i;
    unsigned int cfg = 1;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-b") && i + 1 < argc) bus = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-g") && i + 1 < argc) dev = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-M") && i + 1 < argc) hex = argv[++i];
        else if (!strcmp(argv[i], "-v") || !strcmp(argv[i], "-p") ||
                 !strcmp(argv[i], "-V") || !strcmp(argv[i], "-P")) {
            if (i + 1 < argc) i++;
        } else if (!strcmp(argv[i], "-h")) {
            usage();
            return 0;
        } else {
            usage();
            return 1;
        }
    }

    if (bus < 0 || dev < 0 || !hex) {
        usage();
        return 1;
    }
    n = parse_hex(hex, msg, (int)sizeof msg);
    if (n != 31 || msg[0] != 0x55 || msg[1] != 0x53 || msg[2] != 0x42 || msg[3] != 0x43) {
        fprintf(stderr, "message must be a 31-byte USBC command\n");
        return 1;
    }

    fd = open_busdev(bus, dev);
    if (fd < 0) return 1;

    dlen = read_config(fd, desc, (int)sizeof desc);
    if (dlen < 0) {
        ioctl(fd, USBDEVFS_SETCONFIGURATION, &cfg);
        dlen = read_config(fd, desc, (int)sizeof desc);
    }
    if (dlen < 0 || find_bulk(desc, dlen, &ifnum, &ep_out, &ep_in) != 0) {
        fprintf(stderr, "no bulk endpoint on configuration\n");
        close(fd);
        return 1;
    }

    claim(fd, ifnum);
    if (send_cbw(fd, ep_out, ep_in, msg, n) != 0) {
        close(fd);
        return 1;
    }
    close(fd);
    return 0;
}
