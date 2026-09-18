#!/system/bin/sh
# ==============================================================================
# late_start service : safety net + post-boot diagnostic snapshot.
# module version: v1.5
#
# Some ROMs remount /vendor or /odm after post-fs-data, which silently drops a
# bind mount.  Wait for boot_completed + audioserver, then ask the controller
# how many targets really lost their patch, and re-apply only if at least one
# did.
#
# The check is delegated to `bin/hifi missing` on purpose: this module patches
# TWO different layers, and only one of them carries a text marker.  A policy
# XML can be recognised by grepping for the marker, a vendor HAL library
# (libalsautils*.so) never can -- so a plain grep here would declare the HAL
# target "missing" on every single boot and re-apply the patch in a loop.
#
# Every exit path writes a diagnostic snapshot to
# /data/local/tmp/hifi_src_bypass_report.txt (0644).  /data/adb is root-only and
# on a hardened ROM the adb shell cannot even stat the vendor libraries, so that
# file is the only way to see what happened without root on the PC side -- and
# this run is the interesting one, because by now audioserver is up and the
# framework can tell us which policy file it actually loaded.
# ==============================================================================
MODDIR="${0%/*}"
HIFI="$MODDIR/bin/hifi"
STATE=/data/adb/hifi_src_bypass
LOG="$STATE/last.log"

(
  # one snapshot at whatever moment we leave, then out
  snap() {
    [ -r "$HIFI" ] || exit 0
    HIFI_REPORT_WHY="late-start${1:+: $1}" \
      /system/bin/sh "$HIFI" report >> "$LOG" 2>&1
    exit 0
  }

  i=0
  while [ "$i" -lt 120 ] && [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
    i=$((i + 1))
  done
  [ "$(getprop sys.boot_completed)" = "1" ] || exit 0

  i=0
  while [ "$i" -lt 60 ] && [ "$(getprop init.svc.audioserver)" != "running" ]; do
    sleep 1
    i=$((i + 1))
  done

  [ -r "$STATE/config.conf" ] || exit 0
  grep -q '^ENABLED=1$' "$STATE/config.conf" || snap "disabled"
  [ -r "$HIFI" ] || exit 0

  # no target list -> the controller never managed to prepare anything; let it
  # try once more from scratch instead of staying silently inert
  if [ ! -s "$STATE/targets.lst" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: no target list, re-running apply" >> "$LOG"
    /system/bin/sh "$HIFI" set restart 0 >> "$LOG" 2>&1
    /system/bin/sh "$HIFI" apply >> "$LOG" 2>&1
    /system/bin/sh "$HIFI" set restart 1 >> "$LOG" 2>&1
    snap "no target list"
  fi

  missing="$(/system/bin/sh "$HIFI" missing 2>/dev/null)"
  case "$missing" in ''|*[!0-9]*) missing=-1 ;; esac

  if [ "$missing" = 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: all patched targets still live" >> "$LOG"
    snap "all live"
  fi
  if [ "$missing" = -1 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: could not probe the targets, leaving them alone" >> "$LOG"
    snap "probe failed"
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: $missing target(s) lost the patch, re-applying" >> "$LOG"
  # a remount means the mount was dropped for real, so no audio restart is needed
  /system/bin/sh "$HIFI" set restart 0 >> "$LOG" 2>&1
  /system/bin/sh "$HIFI" apply >> "$LOG" 2>&1
  /system/bin/sh "$HIFI" set restart 1 >> "$LOG" 2>&1
  snap "$missing target(s) re-applied"
) &
