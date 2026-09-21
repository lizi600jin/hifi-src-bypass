#!/system/bin/sh
# ==============================================================================
# HiFi SRC Bypass - installer            v1.8.1
# ------------------------------------------------------------------------------
# Runs under Magisk / KernelSU / APatch.
#
# Unlike the previous (OnePlus-13-only) generation this installer does NOT look
# for one specific policy file.  It reports what the ROM actually exposes and
# lets the on-device controller decide at boot.  Nothing is assumed about the
# vendor, the XML dialect or the file layout.
#
# On an *upgrade* the user settings in /data/adb/hifi_src_bypass/config.conf are
# kept untouched.
# ==============================================================================

ui_print "***************************************************"
ui_print "  HiFi SRC Bypass  (universal)   v1.8.1"
ui_print "  USB / wired dongle high-res passthrough"
ui_print "***************************************************"

DEV="$(getprop ro.product.device)"
MODEL="$(getprop ro.product.model)"
SDK="$(getprop ro.build.version.sdk)"
ROMVER="$(getprop ro.build.display.id)"

ui_print "- device       : $DEV / $MODEL (SDK $SDK)"
[ -n "$ROMVER" ] && ui_print "- rom          : $ROMVER"

if [ -n "$(getprop ro.build.version.oplusrom)" ]; then
  ui_print "- vendor       : ColorOS / OPLUS (Qualcomm AIDL audio)"
elif [ -n "$(getprop ro.miui.ui.version.name)" ]; then
  ui_print "- vendor       : MIUI / HyperOS"
elif [ -n "$(getprop ro.build.version.oneui 2>/dev/null)" ]; then
  ui_print "- vendor       : One UI"
else
  ui_print "- vendor       : AOSP / other"
fi

# ------------------------------------------------- what the ROM actually has
FOUND=""
for f in \
  /odm/etc/audio/audio_module_config_primary.xml \
  /odm/etc/audio/audio_policy_configuration.xml \
  /vendor/etc/audio/audio_module_config_primary.xml \
  /vendor/etc/audio/audio_policy_configuration.xml \
  /vendor/etc/audio_policy_configuration.xml \
  /system/vendor/etc/audio/audio_policy_configuration.xml \
  /system/vendor/etc/audio_policy_configuration.xml
do
  [ -e "$f" ] && FOUND="$FOUND $f"
done
if [ -z "$FOUND" ]; then
  for root in /odm /vendor /system/vendor /product /system/etc; do
    [ -d "$root" ] || continue
    hit="$(find "$root" -maxdepth 6 -type f \
             \( -name 'audio_policy_configuration*.xml' \
                -o -name '*_audio_policy_configuration.xml' \
                -o -name 'audio_module_config_*.xml' \) \
             2>/dev/null)"
    [ -n "$hit" ] && FOUND="$FOUND $hit"
  done
fi

if [ -n "$FOUND" ]; then
  ui_print "- audio policy :"
  for f in $FOUND; do ui_print "      $f"; done
else
  ui_print "! no XML audio policy found."
  ui_print "! This ROM probably predates Android 8 (audio_policy.conf)."
  ui_print "! It installs but stays inert.  Run 'hifi scan' after boot to check."
fi

# ------------------------------------------- the second (hardware) ceiling
# The XML says what the framework will hand out.  The vendor USB HAL library
# keeps its own rate table, and that is the ceiling the DAC really sees.
HALFOUND=""
for d in /odm/lib64 /odm/lib /vendor/lib64 /vendor/lib \
         /system/vendor/lib64 /system/vendor/lib; do
  for l in libalsautils.so libalsautilsv2.so; do
    [ -e "$d/$l" ] && HALFOUND="$HALFOUND $d/$l"
  done
done
if [ -n "$HALFOUND" ]; then
  ui_print "- USB HAL library (rate table to unlock) :"
  for f in $HALFOUND; do ui_print "      $f"; done
else
  ui_print "- USB HAL library : not found"
  ui_print "  (this ROM uses a vendor-written USB HAL, so only the policy layer"
  ui_print "   applies -- that is fine, the module detects it at every boot)"
fi

# ------------------------------------------------------------- state dir init
STATE=/data/adb/hifi_src_bypass
mkdir -p "$STATE/stock" "$STATE/patched" 2>/dev/null
chmod 0755 "$STATE" "$STATE/stock" "$STATE/patched" 2>/dev/null

if [ -r "$STATE/config.conf" ]; then
  ui_print "- existing settings kept (update in place)"
  grep -q '^HAL_PATCH=' "$STATE/config.conf" || {
    printf 'HAL_PATCH=1\n' >> "$STATE/config.conf"
    ui_print "- added the new HAL_PATCH=1 setting (USB HAL layer enabled)"
  }
else
  cat > "$STATE/config.conf" <<'EOF'
MIXER_RATE=48000
MAX_RATE=384000
BIT_DEPTH=32
ENABLED=1
RESTART=1
HAL_PATCH=1
EOF
  chmod 0644 "$STATE/config.conf" 2>/dev/null
  ui_print "- defaults written: mixer 48000 Hz / ceiling 384000 Hz / 32-bit"
  ui_print "  both layers enabled (policy XML + USB HAL library)"
fi

# ------------------------------------------------------- previous generation
OLD_STATE=/data/adb/op13_hifi
if [ -r "$OLD_STATE/config.conf" ]; then
  ui_print "- the OnePlus-13-only module's settings were found, adopting them"
fi
if [ -d /data/adb/modules/op13_hifi_src_bypass ] || [ -d /data/adb/modules_update/op13_hifi_src_bypass ]; then
  ui_print "! IMPORTANT: the previous module (op13_hifi_src_bypass) is still installed."
  ui_print "! Two modules must not bind-mount the same audio policy. Remove one of"
  ui_print "! them in your module manager, then reboot."
fi

# ------------------------------------------------------------------- permissions
if command -v set_perm >/dev/null 2>&1; then
  set_perm "$MODPATH/bin/hifi"        0 0 0755
  set_perm "$MODPATH/bin/probe192.sh" 0 0 0755
  set_perm "$MODPATH/payload/patch_hal.sh" 0 0 0755
  set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
  set_perm "$MODPATH/service.sh"      0 0 0755
  set_perm "$MODPATH/action.sh"       0 0 0755
  set_perm "$MODPATH/uninstall.sh"    0 0 0755
  set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644
  set_perm_recursive "$MODPATH/payload" 0 0 0755 0644
else
  chmod 0755 "$MODPATH/bin/hifi" "$MODPATH/bin/probe192.sh" \
             "$MODPATH/payload/patch_hal.sh" \
             "$MODPATH/post-fs-data.sh" "$MODPATH/service.sh" \
             "$MODPATH/action.sh" "$MODPATH/uninstall.sh" 2>/dev/null
  chmod 0644 "$MODPATH/payload/"* "$MODPATH/webroot/"* 2>/dev/null
fi

# adopt the old generation's settings, if any (runs our controller once)
[ -r "$OLD_STATE/config.conf" ] && /system/bin/sh "$MODPATH/bin/hifi" migrate >/dev/null 2>&1

# --------------------------------------------------------------- sanity output
ui_print ""
ui_print "- two layers  : policy XML + USB HAL library rate table (both on by default)"
ui_print "- presets     : auto | 384k | 192k | 96k | 44k (44.1k library)"
ui_print "- one-tap restore : module action button, or the WebUI button,"
ui_print "                    or: sh /data/adb/modules/hifi_src_bypass/bin/hifi restore"
ui_print "- reboot to activate"
ui_print "- KernelSU / APatch: open this module page -> WebUI"
ui_print "- Magisk: use the action button, or a terminal"
ui_print ""
ui_print "- 安全提示 / Safety note:"
ui_print "  若重启后开机异常（卡屏/无声），在 root 管理器禁用本模块"
ui_print "  或用 Recovery 删除本模块即可完全恢复，数据无损。"
ui_print "  If the next boot misbehaves (stuck logo / no audio), disable this"
ui_print "  module in your root manager or remove it from Recovery to fully"
ui_print "  recover -- no data will be lost."
