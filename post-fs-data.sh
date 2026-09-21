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
# Boot safety net v1.9.2 (P0-1): the K80 boot stall showed that bin/hifi boot
# can hang in post-fs-data.  If a working `timeout` binary is available, run
# the boot pass under it; on timeout the run is marked degraded in the state
# dir so the next boot takes the fast discover-only path (see do_boot).  No
# timeout binary -> fall back to the unprotected legacy behaviour.
STATE="${HIFI_STATE:-/data/adb/hifi_src_bypass}"
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || echo /system/bin/timeout)"
# shell used to exec the controller: /system/bin/sh on the device; fall back
# to whatever `sh` resolves to when that absolute path does not exist (this
# keeps the script testable on a desktop where /system/bin does not exist)
SHELL_BIN=/system/bin/sh
command -v /system/bin/sh >/dev/null 2>&1 || SHELL_BIN=sh
# probe the timeout binary with a real 1s run: GNU coreutils, busybox and
# toybox all accept `timeout 1 true`; a bare `timeout true` is ambiguous on
# some builds (it parses "true" as the DURATION and then fails).
if [ -x "$TIMEOUT_BIN" ] && "$TIMEOUT_BIN" 1 true 2>/dev/null; then
  if ! "$TIMEOUT_BIN" 8 "$SHELL_BIN" "$MODDIR/bin/hifi" boot >/dev/null 2>&1; then
    mkdir -p "$STATE" 2>/dev/null
    touch "$STATE/boot_degraded" 2>/dev/null
  fi
else
  # no timeout available: run unprotected (legacy behaviour)
  "$SHELL_BIN" "$MODDIR/bin/hifi" boot >/dev/null 2>&1
fi

# post-fs-data phase snapshot (service.sh writes the main one later)
HIFI_REPORT_WHY=post-fs-data \
  /system/bin/sh "$MODDIR/bin/hifi" report \
  /data/local/tmp/hifi_src_bypass_report_boot.txt >/dev/null 2>&1
exit 0
