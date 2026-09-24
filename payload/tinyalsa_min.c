/* =============================================================================
 * tinyalsa_min.c -- a minimal static tinymix replacement (no libtinyalsa)
 * -----------------------------------------------------------------------------
 * License: released to the public domain under CC0; alternatively distributable
 *          under the MIT License (any copyright claim waived, attribution not
 *          required).  Ship it, strip it, embed it -- no strings attached.
 *
 * Purpose: several ROMs -- MediaTek devices in particular -- ship WITHOUT the
 * tinymix userland binary, which blinds every mixer read/write tool on the
 * phone.  ~130 lines of pure kernel UAPI (<sound/asound.h>, no libtinyalsa,
 * no Android headers) drive /dev/snd/controlC0 through four ioctls:
 * SNDRV_CTL_IOCTL_ELEM_LIST / _INFO / _READ / _WRITE.  Static-linked it runs
 * on any arm64 Android (and on any other aarch64 Linux).
 *
 * Output dialect: deliberately mimics the OLD (pre-toybox, Redmi K20 Pro)
 * tinymix "legacy 3-tab-field" shape, because that is what the HiFi SRC Bypass
 * controller's _pa_dump_norm() / pa_get() parsers canonicalise on:
 *
 *   tinymix_min             full dump, one row per control:
 *                             "<num>\t<name>\t<current> [<enum tail...>]"
 *                           enumerated controls list every choice, the current
 *                           one first and prefixed with ">" (" >On Off"):
 *                             3174\tTFA Profile\t>SPEAKER Profile_Speaker
 *   tinymix_min <num>       single read, same row shape
 *   tinymix_min <num> <val> write (int / 1|0|on|off for bool / enum-by-name)
 *                           then read back in the same shape
 *
 * Build (arm64, static, ~33 KB):
 *   zig cc -target aarch64-linux-musl -static -Os -s -o tinymix_min tinyalsa_min.c
 * or with a glibc cross toolchain (~650 KB, larger but equally static):
 *   aarch64-linux-gnu-gcc -static -Os -s -o tinymix_min tinyalsa_min.c
 * Host sanity build:
 *   cc -static -Os -s -o tinymix_min_host tinyalsa_min.c
 * =============================================================================
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sound/asound.h>

static int fd;

static int get_info(unsigned num, struct snd_ctl_elem_info *i) {
    memset(i, 0, sizeof *i);
    i->id.numid = num;
    return ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, i);
}

static int read_ctl(unsigned num, struct snd_ctl_elem_value *v) {
    memset(v, 0, sizeof *v);
    v->id.numid = num;
    return ioctl(fd, SNDRV_CTL_IOCTL_ELEM_READ, v);
}

/* Print the value part of the row: the CURRENT value first (a leading ">"
 * marks it on enumerated controls), then the full enum tail -- the exact
 * legacy-tinymix shape "<current> <enum> [<enum>...]" the controller parses.
 */
static void print_value(struct snd_ctl_elem_info *i, struct snd_ctl_elem_value *v) {
    unsigned t = i->type, n = i->count, k;

    if (t == SNDRV_CTL_ELEM_TYPE_ENUMERATED) {
        unsigned cur = v->value.enumerated.item[0];
        unsigned m = i->value.enumerated.items;
        struct snd_ctl_elem_info e;
        int first = 1;
        for (k = 0; k < m; k++) {
            e = *i;
            e.value.enumerated.item = k;
            if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &e) < 0) continue;
            printf("%s%s%s", first ? "" : " ", (k == cur) ? ">" : "",
                   e.value.enumerated.name);
            first = 0;
        }
        if (first) printf("(enum?)");
        return;
    }
    for (k = 0; k < n && k < 8; k++) {
        long long val = 0;
        if (t == SNDRV_CTL_ELEM_TYPE_BOOLEAN ||
            t == SNDRV_CTL_ELEM_TYPE_INTEGER)
            val = v->value.integer.value[k];
        else if (t == SNDRV_CTL_ELEM_TYPE_INTEGER64)
            val = v->value.integer64.value[k];
        else { printf("-"); return; }        /* BYTE / other: not parseable */
        printf("%s%lld", k ? " " : "", val);
    }
}

static void print_row(unsigned num, struct snd_ctl_elem_info *i,
                      struct snd_ctl_elem_value *v) {
    printf("%u\t%s\t", num, i->id.name);
    print_value(i, v);
    printf("\n");
}

int main(int argc, char **argv) {
    struct snd_ctl_elem_list l;
    memset(&l, 0, sizeof l);
    fd = open("/dev/snd/controlC0", O_RDWR);
    if (fd < 0) { perror("open /dev/snd/controlC0"); return 1; }
    if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &l) < 0) { perror("ELEM_LIST"); return 1; }

    unsigned total = l.count;
    if (argc == 1) {                        /* full dump */
        struct snd_ctl_elem_id *ids = calloc(total ? total : 1, sizeof *ids);
        if (!ids) { fprintf(stderr, "oom\n"); return 1; }
        l.space = total; l.pids = ids;
        if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &l) < 0) { perror("ELEM_LIST2"); return 1; }
        for (unsigned n = 0; n < total; n++) {
            unsigned num = ids[n].numid;
            struct snd_ctl_elem_info i; struct snd_ctl_elem_value v;
            if (get_info(num, &i) < 0) continue;      /* hole in the numids */
            if (read_ctl(num, &v) < 0) continue;      /* write-only control */
            print_row(num, &i, &v);
        }
        free(ids);
    } else if (argc == 2) {                 /* single read */
        unsigned num = (unsigned)strtoul(argv[1], 0, 10);
        struct snd_ctl_elem_info i; struct snd_ctl_elem_value v;
        if (get_info(num, &i) < 0) { fprintf(stderr, "Invalid mixer control: %u\n", num); return 1; }
        if (read_ctl(num, &v) < 0) { fprintf(stderr, "read failed: %u\n", num); return 1; }
        print_row(num, &i, &v);
    } else {                                /* write + read-back */
        unsigned num = (unsigned)strtoul(argv[1], 0, 10);
        const char *val = argv[2];
        struct snd_ctl_elem_info i; struct snd_ctl_elem_value v;
        if (get_info(num, &i) < 0) { fprintf(stderr, "Invalid mixer control: %u\n", num); return 1; }
        memset(&v, 0, sizeof v); v.id.numid = num;
        if (i.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED) {
            unsigned m = i.value.enumerated.items, hit = m;
            for (unsigned e = 0; e < m; e++) {
                struct snd_ctl_elem_info ei = i; ei.value.enumerated.item = e;
                if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &ei) == 0 &&
                    strcmp(ei.value.enumerated.name, val) == 0) { hit = e; break; }
            }
            if (hit == m) { fprintf(stderr, "bad enum value: %s\n", val); return 1; }
            v.value.enumerated.item[0] = hit;
        } else if (i.type == SNDRV_CTL_ELEM_TYPE_BOOLEAN) {
            /* the old tinymix writes booleans as digits; accept the words too */
            v.value.integer.value[0] =
                (strcmp(val, "1") == 0 || strcasecmp(val, "on") == 0 ||
                 strcasecmp(val, "true") == 0) ? 1 : 0;
        } else if (i.type == SNDRV_CTL_ELEM_TYPE_INTEGER64) {
            for (unsigned k = 0; k < i.count && k < 8; k++)
                v.value.integer64.value[k] = strtoll(val, 0, 10);
        } else if (i.type == SNDRV_CTL_ELEM_TYPE_INTEGER) {
            for (unsigned k = 0; k < i.count && k < 8; k++)
                v.value.integer.value[k] = atoi(val);
        } else {
            fprintf(stderr, "unsupported control type: %u\n", i.type); return 1;
        }
        if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &v) < 0) { perror("ELEM_WRITE"); return 1; }
        if (get_info(num, &i) == 0 && read_ctl(num, &v) == 0) print_row(num, &i, &v);
    }
    close(fd);
    return 0;
}
