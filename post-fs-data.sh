#!/system/bin/sh
# ==============================================================================
# post-fs-data : patch + mount the audio policy before audioserver starts.
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
# the vendor libraries, so that file is the only way to see what happened
# without root on the PC side -- and `adb pull` can read it.
#
# ---------------------------------------------------------------------------
# BOUNDED-BY-CONSTRUCTION (the "stuck on the first screen" hardening):
#
# post-fs-data runs SYNCHRONOUSLY inside the module manager: init does not
# continue until this script returns.  Whatever this script blocks on is what
# the user stares at, so there is exactly one rule here -- NO unbounded
# external call.  Every controller invocation goes through run_bounded(), and
# when the ROM ships no usable `timeout` binary the run is SKIPPED instead of
# run unprotected (the old fallback ran `hifi boot` with no upper bound at
# all: one hang there and the boot never leaves the logo).
#
# A skipped or failed pass writes $STATE/boot_degraded.  do_boot() reads that
# mark and skips its own mount, so the NEXT boot does not repeat the slow path;
# late_start (service.sh) owns the decision from there.  Everything below ends
# in `exit 0`: this script must never be the reason a phone fails to boot.
# ==============================================================================
MODDIR="${0%/*}"
[ -x "$MODDIR/bin/hifi" ] || chmod 0755 "$MODDIR/bin/hifi" 2>/dev/null

STATE="${HIFI_STATE:-/data/adb/hifi_src_bypass}"
LOG="$STATE/last.log"

# shell used to exec the controller: /system/bin/sh on the device; fall back
# to whatever `sh` resolves to when that absolute path does not exist (this
# keeps the script testable on a desktop where /system/bin does not exist)
SHELL_BIN=/system/bin/sh
[ -x /system/bin/sh ] || SHELL_BIN=sh

note() {
  mkdir -p "$STATE" 2>/dev/null
  printf '%s post-fs-data: %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" \
    >> "$LOG" 2>/dev/null
}

mark_degraded() {
  mkdir -p "$STATE" 2>/dev/null
  : > "$STATE/boot_degraded" 2>/dev/null
  note "degraded mark set: $*"
}

# ---------------------------------------------------------------- timeout probe
# Absolute paths first (a bare `command -v timeout` can silently pick up a
# busybox applet on one ROM and nothing on the next, which is how the two
# scripts ended up with different robustness).  The probe is a REAL run --
# GNU coreutils, busybox and toybox all accept `timeout 1 true`, while a bare
# `timeout true` is ambiguous on some builds (it parses "true" as DURATION).
TIMEOUT_BIN=""
for c in "$HIFI_TIMEOUT_BIN" /system/bin/timeout /system/xbin/timeout; do
  [ -n "$c" ] || continue
  if [ -x "$c" ] && "$c" 1 true 2>/dev/null; then TIMEOUT_BIN="$c"; break; fi
done
if [ -z "$TIMEOUT_BIN" ]; then
  c="$(command -v timeout 2>/dev/null)"
  if [ -n "$c" ] && "$c" 1 true 2>/dev/null; then TIMEOUT_BIN="$c"; fi
fi

# `-k` (kill after grace) is the only way to reap a controller that forked its
# own children: plain `timeout` TERMs the direct child only, and the orphaned
# grandchildren keep running past the bound.  Probe once, then use it.
TIMEOUT_KILL=""
if [ -n "$TIMEOUT_BIN" ] && "$TIMEOUT_BIN" -k 2 1 true 2>/dev/null; then
  TIMEOUT_KILL="-k 2"
fi

# run_bounded <seconds> <cmd...> : the one entry point for every external call.
# Returns the command's status, 124 on timeout, or 127 when no usable timeout
# binary exists -- 127 is deliberate: it can never be confused with success.
run_bounded() {
  _t="$1"; shift
  [ -n "$TIMEOUT_BIN" ] || return 127
  if [ -n "$TIMEOUT_KILL" ]; then
    "$TIMEOUT_BIN" $TIMEOUT_KILL "$_t" "$@"
  else
    "$TIMEOUT_BIN" "$_t" "$@"
  fi
}

# ------------------------------------------------------- boot pass (bounded)
# 8s: the controller's boot pass is a discover + patch + verify sweep over a
# handful of files.  It is bounded, so a conflicting module that makes any
# single call hang cannot hold post-fs-data open any longer than this.
if [ -n "$TIMEOUT_BIN" ]; then
  if ! run_bounded 8 "$SHELL_BIN" "$MODDIR/bin/hifi" boot >/dev/null 2>&1; then
    mark_degraded "boot pass failed or timed out (8s)"
  fi
else
  # No usable timeout binary: do NOT run the controller unbounded -- skipping
  # costs one boot of patch latency, hanging costs the boot itself.
  mark_degraded "no usable timeout binary -- boot pass skipped"
fi

# ------------------------------------------------- post-fs-data phase snapshot
# This call is NOT free either: a conflicting module can hang `hifi report`
# just as easily, and post-fs-data is synchronous, so a hang here shows up as
# a stuck boot logo.  Same bound, and no unprotected fallback.
run_bounded 15 env HIFI_REPORT_WHY=post-fs-data \
  "$SHELL_BIN" "$MODDIR/bin/hifi" report \
  /data/local/tmp/hifi_src_bypass_report_boot.txt >/dev/null 2>&1

# Deliberately unconditional: whatever happened above, release the boot.  A
# non-zero exit from post-fs-data is treated by the module managers as a failed
# stage and can itself stall or roll back the boot.
exit 0
