#!/system/bin/sh
# ==============================================================================
# late_start service : safety net + post-boot diagnostic snapshot.
#
# Some ROMs remount /vendor or /odm after post-fs-data, which silently drops a
# bind mount.  Wait for boot_completed + audioserver, then ask the controller
# how many targets really lost their patch, and re-apply only if at least one
# did.
#
# The check is delegated to `bin/hifi missing` on purpose: this module patches
# TWO different layers, and only one of them carries a text marker.  A policy
# XML can be recognised by grepping for the marker, a vendor HAL library
# (libalsautils.so) never can -- so a plain grep here would declare the HAL
# target "missing" on every single boot and re-apply the patch in a loop.
#
# Every exit path writes a diagnostic snapshot to
# /data/local/tmp/hifi_src_bypass_report.txt (0644).  /data/adb is root-only and
# on a hardened ROM the adb shell cannot even stat the vendor libraries, so that
# file is the only way to see what happened without root on the PC side -- and
# this run is the interesting one, because by now audioserver is up and the
# framework can tell us which policy file it actually loaded.
#
# ---------------------------------------------------------------------------
# LATE_START MUST NEVER BE THE REASON A BOOT STALLS EITHER (the "stuck on the
# first/second screen" hardening):
#
#   * this body already runs in a subshell (`( ... ) &`), so it cannot hold
#     init open -- but it can still burn minutes of CPU/IO on a crash-looping
#     ROM, and a conflicting module can make any controller call hang forever.
#     EVERY call therefore goes through hifi_b(), which is bounded.
#   * no usable `timeout` binary -> the call is SKIPPED, never run unbounded.
#     The old code used a bare PATH `timeout` here while post-fs-data.sh probed
#     absolute paths, so the two scripts disagreed about whether the bound
#     existed at all.
#   * the wait budget below is deliberately tight: audioserver is given 45s,
#     not 60s, and the healthy-confirmation is a 3-poll check instead of one
#     blind `sleep 10`.  Long sleeps here do not help anyone -- they only make
#     the emergency unmount (P0-4) arrive later, and a rescue module elsewhere
#     on the device is already counting boot seconds.
# ==============================================================================
MODDIR="${0%/*}"
HIFI="$MODDIR/bin/hifi"

STATE="${HIFI_STATE:-/data/adb/hifi_src_bypass}"
LOG="$STATE/last.log"

note() {
  mkdir -p "$STATE" 2>/dev/null
  printf '%s service: %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" \
    >> "$LOG" 2>/dev/null
}

# ----------------------------------------------------------- timeout resolution
# Same shape as post-fs-data.sh so both stages agree: absolute paths first, then
# PATH.  The probe is a REAL run -- a bare `timeout true` is ambiguous on some
# builds (they parse "true" as the DURATION).
TIMEOUT_BIN=""
for c in "$HIFI_TIMEOUT_BIN" /system/bin/timeout /system/xbin/timeout; do
  [ -n "$c" ] || continue
  if [ -x "$c" ] && "$c" 1 true 2>/dev/null; then TIMEOUT_BIN="$c"; break; fi
done
if [ -z "$TIMEOUT_BIN" ]; then
  c="$(command -v timeout 2>/dev/null)"
  if [ -n "$c" ] && "$c" 1 true 2>/dev/null; then TIMEOUT_BIN="$c"; fi
fi
TIMEOUT_KILL=""
if [ -n "$TIMEOUT_BIN" ] && "$TIMEOUT_BIN" -k 2 1 true 2>/dev/null; then
  TIMEOUT_KILL="-k 2"
fi

# hifi_b <seconds> <subcommand...> : the single entry point for every controller
# call.  Every call site below uses it, so no path can reach the controller
# without a bound.  Returns 124 on timeout, 127 when no usable timeout exists
# (127 can never be mistaken for success).
hifi_b() {
  _t="$1"; shift
  [ -n "$TIMEOUT_BIN" ] || return 127
  [ -r "$HIFI" ] || return 127
  if [ -n "$TIMEOUT_KILL" ]; then
    "$TIMEOUT_BIN" $TIMEOUT_KILL "$_t" sh "$HIFI" "$@"
  else
    "$TIMEOUT_BIN" "$_t" sh "$HIFI" "$@"
  fi
}

# transient_set <key> <value> : change one setting for THIS RUN ONLY.
# HIFI_TRANSIENT=1 makes bin/hifi's do_set skip save_conf, so the user's own
# config.conf value survives.  The old call was `HIFI_RESTART=0 hifi_t 10 set
# restart 0`: HIFI_RESTART appeared nowhere in bin/hifi (pure no-op) and the
# restart branch still fell through to save_conf, so the boot self-heal
# permanently rewrote the user's RESTART to 0 with no recovery point.
transient_set() {
  HIFI_TRANSIENT=1 hifi_b 10 set "$1" "$2"
}

snap() {
  # one diagnostic snapshot at whatever moment we leave, then out
  [ -r "$HIFI" ] || exit 0
  HIFI_REPORT_WHY="late-start${1:+: $1}" hifi_b 10 report >> "$LOG" 2>&1
  exit 0
}

(
  if [ -z "$TIMEOUT_BIN" ]; then
    note "no usable timeout binary -- controller calls will be skipped this boot"
    exit 0
  fi

  # boot_completed: 120 polls of 1s.  Cheap and bounded; the subshell does not
  # block init, so a slow boot simply means this pass runs later.
  i=0
  while [ "$i" -lt 120 ] && [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
    i=$((i + 1))
  done
  [ "$(getprop sys.boot_completed)" = "1" ] || exit 0

  # audioserver: 45 polls of 1s (budget tightened from 60).
  i=0
  while [ "$i" -lt 45 ] && [ "$(getprop init.svc.audioserver)" != "running" ]; do
    sleep 1
    i=$((i + 1))
  done

  # ---- boot safety net v1.9.2 (P0-2 + P0-4) --------------------------------
  # The K80 boot-stall reports showed two failure shapes that must never end
  # in a stuck boot animation:
  #   P0-4  audioserver never came up (or died right away) with the patch
  #         mounted -> the patch config is being rejected.  Unmount it right
  #         now: the user keeps a working phone and merely loses the patch.
  #   P0-2  the same thing happened on 2 consecutive boots -> additionally
  #         clear the enabled flag so the next boot does not re-mount at all.
  # Both are one-shot scripts here -- no daemon, no background loop.
  # The 2s/4s confirmation polls below replace the old single `sleep 10`: they
  # give the service the same evidence (it was up, and it stayed up) for a
  # fraction of the latency, so the emergency unmount arrives sooner.
  _as_up=0
  if [ "$(getprop init.svc.audioserver)" = "running" ]; then
    for _p in 1 2 3 4; do
      sleep 2
      [ "$(getprop init.svc.audioserver)" = "running" ] \
        && [ -n "$(pidof audioserver 2>/dev/null)" ] || break
      [ "$_p" -ge 2 ] && _as_up=1
    done
  fi

  if [ "$_as_up" != 1 ]; then
    note "boot verify: audioserver not healthy, unmounting patch (P0-4)"
    # P0-5: restore must never touch the audio stack (it may be crash-looping).
    #
    # The suppression has to travel WITH THE CALL, not through a separate
    # controller run.  The old code did `transient_set restart 0` and then a
    # plain `hifi_b 30 restore`: two different processes, so the transient flag
    # died with the first one, the second re-read RESTART=1 from config.conf
    # and restarted the crashing audioserver anyway (that is finding F2).  Now
    # the flags are on the restore invocation itself and the argument says the
    # same thing three ways, which is deliberate redundancy: whichever of the
    # three a future refactor keeps, the stack is still not touched.
    HIFI_TRANSIENT=1 HIFI_NO_RESTART=1 hifi_b 30 restore --no-restart >> "$LOG" 2>&1
    _bf="$STATE/bootfail.count"
    _n=0
    [ -r "$_bf" ] && _n="$(cat "$_bf" 2>/dev/null)"
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    _n=$((_n + 1))
    printf '%s\n' "$_n" > "$_bf" 2>/dev/null
    if [ "$_n" -ge 2 ]; then
      note "BOOTFAIL-CIRCUIT-BREAK: $_n consecutive unhealthy boots, disabling auto-apply"
      hifi_b 10 set enabled 0 >> "$LOG" 2>&1
      rm -f "$STATE/boot_degraded" 2>/dev/null
    fi
    snap "audioserver unhealthy (P0-4 unmount, bootfail=$_n)"
  fi

  # audioserver healthy: clear any boot-failure history and the degraded mark.
  # The degraded mark is exactly what post-fs-data sets when it skipped or
  # timed out its boot pass, so clearing it here is what lets the NEXT boot
  # take the normal mount path again.
  rm -f "$STATE/bootfail.count" 2>/dev/null
  rm -f "$STATE/boot_degraded" 2>/dev/null

  [ -r "$STATE/config.conf" ] || exit 0
  grep -q '^ENABLED=1$' "$STATE/config.conf" || snap "disabled"
  [ -r "$HIFI" ] || exit 0

  # no target list -> the controller never managed to prepare anything; let it
  # try once more from scratch instead of staying silently inert
  if [ ! -s "$STATE/targets.lst" ]; then
    note "boot verify: no target list, re-running apply"
    # same rule as P0-4: the suppression rides on the apply call.  HD audio is a
    # nice-to-have, a boot loop is not -- never restart the stack from here.
    # Nothing is persisted either (HIFI_TRANSIENT=1), so the user's own RESTART
    # setting survives a self-heal that was never the user's decision.
    HIFI_TRANSIENT=1 HIFI_NO_RESTART=1 hifi_b 30 apply --no-restart >> "$LOG" 2>&1
    snap "no target list"
  fi

  missing="$(hifi_b 10 missing 2>/dev/null)"
  case "$missing" in ''|*[!0-9]*) missing=-1 ;; esac

  if [ "$missing" = 0 ]; then
    note "boot verify: all patched targets still live"
    # WP1: re-assert the ADSP bit-width enforce property once per boot when the
    # config asks for it.  The HAL may have started before late_start and read
    # nothing (first boot after enabling), and a repeated setprop is idempotent.
    # Reading the knob straight from config.conf keeps this a pure property
    # action with no audio-stack dependency; `hifi apply` remains the primary
    # injection point (run on every apply / re-apply).
    if [ -r "$STATE/config.conf" ]; then
      _dsp="$(sed -n 's/^SPK_DSP_BITS=//p' "$STATE/config.conf" 2>/dev/null | head -n1)"
      case "$_dsp" in
        24|32)
          setprop persist.vendor.audio_hal.dsp_bit_width_enforce_mode "$_dsp" 2>/dev/null \
            && note "boot verify: dsp_bit_width_enforce_mode=$_dsp re-asserted"
          ;;
      esac
    fi
    snap "all live"
  fi
  if [ "$missing" = -1 ]; then
    note "boot verify: could not probe the targets, leaving them alone"
    snap "probe failed"
  fi

  note "boot verify: $missing target(s) lost the patch, re-applying"
  # a remount means the mount was dropped for real, so no audio restart is
  # needed -- and it must not be attempted: the previous pair of controller
  # calls (`set restart 1` right after the apply) left the persisted setting
  # rewritten by the self-heal on a device that had merely been slow to boot.
  HIFI_TRANSIENT=1 HIFI_NO_RESTART=1 hifi_b 30 apply --no-restart >> "$LOG" 2>&1
  snap "$missing target(s) re-applied"
) &
