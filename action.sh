#!/system/bin/sh
# ==============================================================================
# Action button (Magisk / KernelSU / APatch)
# module version: v1.8
#
#   not applied  ->  apply the patch
#   applied      ->  ONE-TAP RESTORE, back to the factory audio policy
#
# The restore path is lossless and reversible: it only unmounts the binds and
# sets ENABLED=0.  Your mixer / ceiling / bit-depth settings are kept, so
# tapping the button again re-applies exactly the same configuration.
#
# "is it applied?" is answered by `bin/hifi applied`, not by grepping for the
# text marker -- the USB HAL library layer carries no marker and would always
# read as "not applied" here.
# ==============================================================================
MODDIR="${0%/*}"
HIFI="$MODDIR/bin/hifi"

echo "=============================================="
echo " HiFi SRC Bypass  (universal)"
echo "=============================================="
/system/bin/sh "$HIFI" status
echo ""

applied=0
if [ -x "$HIFI" ] || [ -r "$HIFI" ]; then
  applied="$(/system/bin/sh "$HIFI" applied 2>/dev/null)"
  case "$applied" in ''|*[!0-9]*) applied=0 ;; esac
fi

if [ "$applied" -gt 0 ]; then
  echo "--> the patch is ACTIVE ($applied target(s) live), restoring the factory policy ..."
  echo ""
  /system/bin/sh "$HIFI" restore
else
  echo "--> the factory policy is in use, applying the patch ..."
  echo ""
  /system/bin/sh "$HIFI" set enabled 1 >/dev/null 2>&1
  /system/bin/sh "$HIFI" apply
fi

echo ""
echo "=============================================="
echo " done -- tap the button again to toggle"
echo " fine control: hifi preset auto | 384k | 192k | 96k | 44k"
echo " diagnose    : hifi doctor"
echo "=============================================="
