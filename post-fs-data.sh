#!/system/bin/sh
# ==============================================================================
# post-fs-data : patch + mount the audio policy before audioserver starts.
# module version: v1.8.1
#
# This stage runs in the module manager's own mount namespace, so bin/hifi
# re-execs itself through `nsenter -t 1 -m` to reach the global namespace.
# The factory files themselves are never written to -- a bind mount is used.
#
# Everything is discovered here: every XML policy file that really carries a
# USB / wired / DIRECT output port, AND the vendor USB HAL library
# (libalsautils.so), whose own rate table is the ceiling the DAC actually sees,
# whatever the ROM calls it and wherever it lives.
#
# A read-only diagnostic snapshot is written to /data/local/tmp afterwards.
# /data/adb is root-only and on a hardened ROM the adb shell cannot even stat
# the vendor libraries, so this file is the only way to see what happened
# without root on the PC side -- and `adb pull` can read it.
# ==============================================================================
MODDIR="${0%/*}"
[ -x "$MODDIR/bin/hifi" ] || chmod 0755 "$MODDIR/bin/hifi" 2>/dev/null
/system/bin/sh "$MODDIR/bin/hifi" boot >/dev/null 2>&1

# post-fs-data phase snapshot (service.sh writes the main one later)
HIFI_REPORT_WHY=post-fs-data \
  /system/bin/sh "$MODDIR/bin/hifi" report \
  /data/local/tmp/hifi_src_bypass_report_boot.txt >/dev/null 2>&1
exit 0
