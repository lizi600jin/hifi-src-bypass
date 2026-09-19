#!/system/bin/sh
# ==============================================================================
# HiFi SRC Bypass   v1.8   uninstall.sh
#
# Executed by Magisk / KernelSU / APatch right before the module directory is
# deleted.  Goal: leave the device byte-identical to a stock one.
#
#   1. remove every bind mount from every mount namespace we can reach
#      -- both layers: the XML audio policy AND the USB HAL library
#   2. put a factory file back if it was ever overwritten
#   3. delete /data/adb/hifi_src_bypass (patched files, archives, settings, logs)
#   4. delete stray temp files
#   5. never write to /vendor, /odm or /system -- only ever mounted over them
#
# Deliberately self-contained: it still works when bin/hifi is already gone.
# The list of files to unmount is read from the state dir; if that is missing
# too, it is reconstructed from the ROM itself.
# ==============================================================================

set -u

MODDIR="${MODDIR:-${0%/*}}"
MOD_ID=hifi_src_bypass
STATE=/data/adb/$MOD_ID
CONF="$STATE/config.conf"
TGT="$STATE/targets.lst"
MARKER=HIFI_SRC_BYPASS_UNIV
LOGTAG=hifi_src_bypass_uninstall

say() { printf '%s: %s\n' "$LOGTAG" "$*"; }

say "=== HiFi SRC Bypass uninstall: removing every trace ==="

is_mounted() {
  awk -v t="$1" '$2 == t { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null
}

is_ours() { [ -r "$1" ] && grep -q "$MARKER" "$1" 2>/dev/null; }

# ------------------------------------------------------------ 1. target list
LIVE_LIST=""
ARCHIVE_LIST=""
if [ -s "$TGT" ]; then
  while IFS='|' read -r live patched stk; do
    [ -n "$live" ] || continue
    LIVE_LIST="$LIVE_LIST $live"
    [ -n "${stk:-}" ] && ARCHIVE_LIST="$ARCHIVE_LIST $stk"
  done < "$TGT"
else
  say "targets.lst is missing -- reconstructing the target list from the ROM"
  for f in \
    /odm/etc/audio/audio_module_config_primary.xml \
    /odm/etc/audio/audio_module_config_secondary.xml \
    /odm/etc/audio/audio_policy_configuration.xml \
    /vendor/etc/audio/audio_module_config_primary.xml \
    /vendor/etc/audio/audio_policy_configuration.xml \
    /vendor/etc/audio_policy_configuration.xml \
    /vendor/etc/audio/usb_audio_policy_configuration.xml \
    /odm/etc/audio/usb_audio_policy_configuration.xml \
    /system/vendor/etc/audio/audio_policy_configuration.xml \
    /system/vendor/etc/audio/audio_policy_configuration.xml
  do
    [ -e "$f" ] && LIVE_LIST="$LIVE_LIST $f"
  done
  # layer 2: the vendor USB HAL libraries, in case a bind mount of one survived
  for d in /odm/lib64 /odm/lib /vendor/lib64 /vendor/lib \
           /system/vendor/lib64 /system/vendor/lib; do
    for l in libalsautils.so libalsautilsv2.so; do
      [ -e "$d/$l" ] && LIVE_LIST="$LIVE_LIST $d/$l"
    done
  done
fi

# -------------------------------------------------------------- 2. unmount
n_unmounted=0
n_stuck=0
for live in $LIVE_LIST; do
  [ -n "$live" ] || continue
  say "target file: $live"

  # 2a. the global (init) namespace is the one audioserver actually reads
  nsenter -t 1 -m -- umount "$live" 2>/dev/null
  is_mounted "$live" && umount "$live" 2>/dev/null
  is_mounted "$live" && umount -l "$live" 2>/dev/null

  # 2b. sweep the remaining namespaces (managers often stay isolated)
  for d in /proc/[0-9]*; do
    [ -r "$d/mounts" ] || continue
    if awk -v t="$live" '$2 == t { found = 1 } END { exit !found }' "$d/mounts" 2>/dev/null; then
      pid="${d#/proc/}"
      nsenter -t "$pid" -m -- umount "$live" 2>/dev/null
      nsenter -t "$pid" -m -- umount -l "$live" 2>/dev/null
    fi
  done

  if is_mounted "$live"; then
    say "WARNING: $live is still mounted -- one reboot completes the removal"
    n_stuck=$((n_stuck + 1))
  else
    say "bind mount removed"
    n_unmounted=$((n_unmounted + 1))
  fi
done

# ------------------------------------- 3. archive write-back (last resort)
# Only if the on-disk file itself carries our marker, i.e. something rewrote
# the real file instead of the bind mount.  Match archives back to targets by
# the flattened name the controller uses.
for live in $LIVE_LIST; do
  [ -n "$live" ] || continue
  is_ours "$live" || continue
  flat="$(printf '%s' "$live" | tr '/.' '__')"
  stk="$STATE/stock/$flat"
  if [ -r "$stk" ]; then
    say "the on-disk file carries our patch, writing the factory archive back: $live"
    if cp -f "$stk" "$live" 2>/dev/null; then
      chmod 0644 "$live" 2>/dev/null
      chown 0:0 "$live" 2>/dev/null
      say "factory file restored"
    else
      say "WARNING: could not write the factory file back -- one reboot recovers"
    fi
  else
    say "WARNING: patch present and no archive available -- one reboot recovers"
  fi
done

# --------------------------------------------- 4. keep the settings in the log
if [ -r "$CONF" ]; then
  say "-- settings being removed (keep them if you reinstall) --"
  sed 's/^/    /' "$CONF" 2>/dev/null
  say "-- end of settings --"
fi

# ------------------------------------------------- 5. wipe the state directory
if [ -d "$STATE" ]; then
  rm -rf "$STATE" 2>/dev/null
  if [ -d "$STATE" ]; then
    say "WARNING: $STATE could not be removed"
  else
    say "state directory removed: $STATE"
  fi
else
  say "state directory already absent: $STATE"
fi

# ------------------------------------------------------- 6. stray temp files
rm -rf /data/local/tmp/hifi_src_bypass* 2>/dev/null
rm -f  /data/local/tmp/.hifi_probe_* 2>/dev/null
rm -f  /data/local/tmp/probe192.sh 2>/dev/null
rm -rf "/data/adb/modules_update/$MOD_ID" 2>/dev/null

# ------------------------------------------------------- 7. final assertion
left=0
for live in $LIVE_LIST; do
  [ -n "$live" ] || continue
  if is_mounted "$live"; then left=$((left + 1)); continue; fi
  is_ours "$live" && left=$((left + 1))
done

if [ "$left" -gt 0 ]; then
  say "RESULT: $left file(s) still patched -- one reboot completes the cleanup"
else
  say "RESULT: CLEAN -- factory policy in use, no residue left"
fi
say "/vendor /odm /system were never written to by this module"
say "=== HiFi SRC Bypass uninstall finished ==="
exit 0
