#!/system/bin/sh
# ==============================================================================
# late_start service : safety net + post-boot diagnostic snapshot.
# module version: v1.8.1
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
STATE="${HIFI_STATE:-/data/adb/hifi_src_bypass}"
LOG="$STATE/last.log"

(
  # one snapshot at whatever moment we leave, then out
  snap() {
    [ -r "$HIFI" ] || exit 0
    HIFI_REPORT_WHY="late-start${1:+: $1}" \
      sh "$HIFI" report >> "$LOG" 2>&1
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

  # ---- boot safety net v1.9.2 (P0-2 + P0-4) --------------------------------
  # The K80 boot-stall reports showed two failure shapes that must never end
  # in a stuck boot animation:
  #   P0-4  audioserver never came up (or died right away) with the patch
  #         mounted -> the patch config is being rejected.  Unmount it right
  #         now: the user keeps a working phone and merely loses the patch.
  #   P0-2  the same thing happened on 2 consecutive boots -> additionally
  #         clear the enabled flag so the next boot does not re-mount at all.
  # Both are one-shot scripts here -- no daemon, no background loop.
  _as_up=0
  if [ "$(getprop init.svc.audioserver)" = "running" ]; then
    # running right after the wait loop; give it a moment and confirm it STAYS
    sleep 10
    if [ "$(getprop init.svc.audioserver)" = "running" ] \
       && [ -n "$(pidof audioserver 2>/dev/null)" ]; then
      _as_up=1
    fi
  fi

  if [ "$_as_up" != 1 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: audioserver not healthy, unmounting patch (P0-4)" >> "$LOG"
    # P0-5: restore must never touch the audio stack (it may be crash-looping).
    # RESTART is persisted config, so zero it for this run without saving.
    HIFI_RESTART=0 sh "$HIFI" set restart 0 >> "$LOG" 2>&1
    HIFI_RESTART=0 sh "$HIFI" restore >> "$LOG" 2>&1
    _bf="$STATE/bootfail.count"
    _n=0
    [ -r "$_bf" ] && _n="$(cat "$_bf" 2>/dev/null)"
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    _n=$((_n + 1))
    printf '%s\n' "$_n" > "$_bf" 2>/dev/null
    if [ "$_n" -ge 2 ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') BOOTFAIL-CIRCUIT-BREAK: $_n consecutive unhealthy boots, disabling auto-apply" >> "$LOG"
      sh "$HIFI" set enabled 0 >> "$LOG" 2>&1
      rm -f "$STATE/boot_degraded" 2>/dev/null
    fi
    snap "audioserver unhealthy (P0-4 unmount, bootfail=$_n)"
  fi

  # audioserver healthy: clear any boot-failure history and the degraded mark
  rm -f "$STATE/bootfail.count" 2>/dev/null
  rm -f "$STATE/boot_degraded" 2>/dev/null

  [ -r "$STATE/config.conf" ] || exit 0
  grep -q '^ENABLED=1$' "$STATE/config.conf" || snap "disabled"
  [ -r "$HIFI" ] || exit 0

  # no target list -> the controller never managed to prepare anything; let it
  # try once more from scratch instead of staying silently inert
  if [ ! -s "$STATE/targets.lst" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: no target list, re-running apply" >> "$LOG"
    sh "$HIFI" set restart 0 >> "$LOG" 2>&1
    sh "$HIFI" apply >> "$LOG" 2>&1
    sh "$HIFI" set restart 1 >> "$LOG" 2>&1
    snap "no target list"
  fi

  missing="$(sh "$HIFI" missing 2>/dev/null)"
  case "$missing" in ''|*[!0-9]*) missing=-1 ;; esac

  if [ "$missing" = 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: all patched targets still live" >> "$LOG"
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
            && echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: dsp_bit_width_enforce_mode=$_dsp re-asserted" >> "$LOG"
          ;;
      esac
    fi
    snap "all live"
  fi
  if [ "$missing" = -1 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: could not probe the targets, leaving them alone" >> "$LOG"
    snap "probe failed"
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: $missing target(s) lost the patch, re-applying" >> "$LOG"
  # a remount means the mount was dropped for real, so no audio restart is needed
  sh "$HIFI" set restart 0 >> "$LOG" 2>&1
  sh "$HIFI" apply >> "$LOG" 2>&1
  sh "$HIFI" set restart 1 >> "$LOG" 2>&1
  snap "$missing target(s) re-applied"
) &
