#!/system/bin/sh
# ==============================================================================
# HiFi SRC Bypass - deep verification (sampling rate + bit depth)
#                                        probe192.sh           v1.9.1
#
#   usage A (module installed):
#     su -c "sh /data/adb/modules/hifi_src_bypass/bin/probe192.sh"
#     su -c "/data/adb/modules/hifi_src_bypass/bin/hifi doctor"
#
#   usage B (adb push):
#     adb push probe192.sh /data/local/tmp/
#     adb shell su -c "sh /data/local/tmp/probe192.sh"
#
#   section filter (used by the WebUI to show the two halves in separate panes):
#     HIFI_PROBE_SECTION=core   -> sections [1]..[7]   (is it really running?)
#     HIFI_PROBE_SECTION=adapt  -> sections [8] + [9]  (device adaptation info)
#     (unset)                   -> everything, as before
#
#   It reports, not guesses:
#     * the factory policy files THIS ROM uses, and whether they are patched
#     * the ports the patcher recognised, per file
#     * four layers of evidence, from "what the config says" down to
#       "what the kernel really negotiated"
#
#   What people usually mis-read (this is the whole point of the script):
#     stream0  Rates / Altset      = what the DAC ADVERTISES   (only "supports")
#     hw_params rate / format      = what is really negotiated right now
#     hw_params owner_pid          = who is playing
#          audioserver             -> Android audio stack, the module is on the path
#          a third-party app       -> the app's own USB driver, the module is irrelevant
#
#   Nothing here is device specific: the port names are read out of this phone's
#   own policy files, so QTI/AIDL (usb_headset) and AOSP/HIDL (USB Headset Out)
#   both work, and so does any ROM that invents its own names.
# ==============================================================================

set -u

# Offline self-test can point these at a fake tree (Windows needs forward slashes)
CARD_ROOT="${HIFI_FAKE_ASOUND:-/proc/asound}"
POLICY_ROOT="${HIFI_FAKE_POLICY_ROOT:-}"
PROOT="${HIFI_FAKE_ROOT:-}"
MOUNTS="${HIFI_FAKE_MOUNTS:-/proc/mounts}"

# core | adapt | "" (both).  See "section filter" above.
SEC_FILTER="${HIFI_PROBE_SECTION:-}"
want_core()  { [ -z "$SEC_FILTER" ] || [ "$SEC_FILTER" = core ]; }
want_adapt() { [ -z "$SEC_FILTER" ] || [ "$SEC_FILTER" = adapt ]; }

MOD_ID=hifi_src_bypass
STATE="${HIFI_STATE_DIR:-/data/adb/$MOD_ID}"
CONFIG="$STATE/config.conf"
TGT="$STATE/targets.lst"
MARKER=HIFI_SRC_BYPASS_UNIV

# Section [8] is a standalone pane (HIFI_PROBE_SECTION=adapt), so it cannot
# rely on section [1]/[1b]/[7] having run -- and `set -u` would make a bare
# reference fatal.  Seed everything the two halves share, right here.
# MODDIR resolves the same way section [7] used to: the controller exports it,
# and a bare `sh probe192.sh` falls back to the script's own parent directory.
if [ -z "${MODDIR:-}" ]; then
  MODDIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
fi
[ -n "${MODDIR:-}" ] || MODDIR="/data/adb/modules/$MOD_ID"
POLICY_FILES=""
POLICY=""

hr()  { printf '%s\n' "------------------------------------------------------------"; }
sec() { printf '\n'; hr; printf '[%s] %s\n' "$1" "$2"; hr; }
show(){ printf '%s\n' "$*"; }

# =============================================================== port resolver
# Classify the ports of one policy file.  Emits lines "CLASS|NAME".
#   USB   -> the dongle (devicePort)
#   WIRED -> 3.5 mm / analog (devicePort)
#   SPK   -> speaker / earpiece (devicePort)
#   DIR   -> DIRECT mixPort (app-exclusive passthrough)
#   MIX   -> mixer mixPort (low_latency / deep_buffer / primary)
port_scan() {
  awk '
  function attr(s,k,   p,i,j){p=k"=\"";i=index(s,p);if(i==0)return "";i+=length(p);j=i;while(j<=length(s)&&substr(s,j,1)!="\"")j++;return substr(s,i,j-i)}
  BEGIN{inc=0}
  {
    line=$0; live=""
    while(line!=""){
      if(inc){i=index(line,"-->"); if(i==0){line=""} else {line=substr(line,i+3);inc=0}}
      else {i=index(line,"<!--"); if(i==0){live=live line;line=""} else {live=live substr(line,1,i-1);line=substr(line,i+4);inc=1}}
    }
    if(live ~ /^[ \t]*<mixPort[ \t>]/){
      nm=attr(live,"name"); fl=attr(live,"flags"); rl=attr(live,"role")
      if(rl=="source"){
        if(fl ~ /DIRECT/ && fl !~ /COMPRESS_OFFLOAD|MMAP_NOIRQ|SPATIALIZER|OFFLOAD|RAW/) print "DIR|" nm
        else if((fl ~ /PRIMARY/ && fl !~ /RAW/) || nm ~ /^(low_latency|deep_buffer)/) print "MIX|" nm
      }
      next
    }
    if(live ~ /^[ \t]*<devicePort[ \t>]/){
      rl=attr(live,"role"); tg=attr(live,"tagName"); tp=attr(live,"type"); cn=attr(live,"connection")
      if(rl!="" && rl!="sink") next
      if(tp ~ /_IN_/) next
      tl=tolower(tg)
      if(tl ~ /(^|[ _-])mic($|[ _-])/ || tl ~ /input/) next
      if(tg=="") next
      if(tp!=""){
        if(tp !~ /_OUT_/) next
        if(tp ~ /USB_ACCESSORY/) next
        if(tp ~ /USB/) { print "USB|" tg; next }
        if(tp ~ /WIRED_HEADSET|WIRED_HEADPHONE/) { print "WIRED|" tg; next }
        if(tp ~ /SPEAKER|EARPIECE/) { print "SPK|" tg; next }
        next
      }
      if(cn ~ /^(bt|hdmi|ip|virtual|proxy|telephony|remote|aux|spdif)/) next
      if(cn=="usb" || tg ~ /usb/) { print "USB|" tg; next }
      if(tg ~ /speaker|earpiece/) { print "SPK|" tg; next }
      if(tg ~ /wired|headset|headphone/) { print "WIRED|" tg; next }
    }
  }' "$1" 2>/dev/null
}

names_of() {  # names_of <class> ; uses PORT_MAP
  awk -F'|' -v c="$1" '$1==c { if (out == "") out=$2; else out=out" "$2 } END { print out }' "$PORT_MAP" 2>/dev/null
}

# strip XML comments (including multi-line ones -- the vendor files hide a
# whole second, disabled copy of the profiles inside <!-- #ifdef -->)
stripc() {
  awk 'BEGIN{inc=0}
  {
    line=$0; out=""
    while (line != "") {
      if (inc) {
        i = index(line, "-->")
        if (i == 0) { line = "" } else { line = substr(line, i+3); inc = 0 }
      } else {
        i = index(line, "<!--")
        if (i == 0) { out = out line; line = "" } else { out = out substr(line, 1, i-1); line = substr(line, i+4); inc = 1 }
      }
    }
    print out
  }'
}

rates_of()  { sed -n 's/.*samplingRates="\([^"]*\)".*/\1/p' | tr ' ' '\n' | grep -E '^[0-9]+$'; }
live_pcms() { grep -o 'pcmType="[^"]*"' | sed 's/pcmType="//; s/"//' | sort -u | tr '\n' ' ' | sed 's/ *$//'; }
live_fmts() { grep -o 'format="[^"]*"' | sed 's/format="//; s/"//' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//'; }

mix_at() {   # mix_at <file> <name> -> live profile lines of that mixPort
  sed -n "/<mixPort name=\"$2\"/,/<\/mixPort>/p" "$1" 2>/dev/null | stripc
}
dev_at() {
  sed -n "/<devicePort tagName=\"$2\"/,/<\/devicePort>/p" "$1" 2>/dev/null | stripc
}
max_rate_of() { rates_of | sort -n | tail -n1; }
has_rate() { rates_of | grep -qx "$2" && echo yes || echo no; }
bits_of_port() {
  L="$(live_pcms)"
  if [ -z "$L" ]; then L="$(live_fmts | tr ' ' '\n' | grep 'AUDIO_FORMAT_' | tr '\n' ' ')"; fi
  case "$L" in
    *INT_32_BIT*|*PCM_32_BIT*) printf '%s' 32 ;;
    *INT_24_BIT*|*PCM_24_BIT_PACKED*|*PCM_8_24_BIT*|*FIXED_Q_8_24*) printf '%s' 24 ;;
    *INT_16_BIT*|*PCM_16_BIT*) printf '%s' 16 ;;
    *) printf '%s' 0 ;;
  esac
}

proc_of() {
  [ -n "${1:-}" ] || return 0
  c=""
  [ -r "/proc/$1/cmdline" ] && c="$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)"
  [ -n "$c" ] || c="$(cat "/proc/$1/comm" 2>/dev/null)"
  printf '%s' "${c:-unknown}"
}

# ==================================================================== header
if want_core; then
printf 'HiFi SRC Bypass - deep verification (sampling rate + bit depth)\n'
else
printf 'HiFi SRC Bypass - device adaptation info (send this to the maintainer)\n'
fi
printf '时间 : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '机型 : %s / %s   SDK %s\n' "$(getprop ro.product.device)" \
       "$(getprop ro.product.model)" "$(getprop ro.build.version.sdk)"
printf 'ROM  : %s\n' "$(getprop ro.build.display.id)"
printf '内核 : %s\n' "$(uname -r 2>/dev/null)"

# ------------------------------------------------ expectations, from the module
# Every "did it reach the target" verdict compares against config.conf.  Never
# against a hard-coded 192k: the user may legitimately have chosen 96k.
CONFIG_MIX="$(sed -n 's/^MIXER_RATE=//p'  "$CONFIG" 2>/dev/null | head -n1)"
CONFIG_MAX="$(sed -n 's/^MAX_RATE=//p'    "$CONFIG" 2>/dev/null | head -n1)"
CONFIG_BITS="$(sed -n 's/^BIT_DEPTH=//p' "$CONFIG" 2>/dev/null | head -n1)"
CONFIG_HIFI="$(sed -n 's/^HIFI_RATE=//p'  "$CONFIG" 2>/dev/null | head -n1)"
CONFIG_SPK="$(sed -n 's/^SPK_RATE=//p'    "$CONFIG" 2>/dev/null | head -n1)"
CONFIG_SPKBITS="$(sed -n 's/^SPK_BITS=//p' "$CONFIG" 2>/dev/null | head -n1)"
CONFIG_DSPBITS="$(getprop persist.vendor.audio_hal.dsp_bit_width_enforce_mode 2>/dev/null)"
CONFIG_SPKDSP="$(sed -n 's/^SPK_DSP_BITS=//p' "$CONFIG" 2>/dev/null | head -n1)"
[ -n "$CONFIG_SPKDSP" ] || CONFIG_SPKDSP=16
# Defensive: missing keys fall back to the same defaults the controller ships
[ -n "$CONFIG_SPK" ]     || CONFIG_SPK=auto
[ -n "$CONFIG_SPKBITS" ] || CONFIG_SPKBITS=16
case "${CONFIG_BITS:-32}" in
  16) WANT_N=1 ;;
  24) WANT_N=2 ;;
  *)  WANT_N=3 ;;
esac

# ==================================================== 1. module and policy files
if want_core; then
sec 1 "模块与生效中的策略文件"
POLICY_FILES=""
POLICY=""
if [ -s "$TGT" ]; then
  while IFS='|' read -r live patched stk; do
    [ -n "$live" ] || continue
    POLICY_FILES="$POLICY_FILES $live"
    [ -z "$POLICY" ] && POLICY="$live"
  done < "$TGT"
fi
if [ -z "$POLICY_FILES" ]; then
  for f in \
    /odm/etc/audio/audio_module_config_primary.xml \
    /odm/etc/audio/audio_policy_configuration.xml \
    /vendor/etc/audio/audio_policy_configuration.xml \
    /vendor/etc/audio/audio_module_config_primary.xml \
    /system/vendor/etc/audio/audio_policy_configuration.xml \
    /system/etc/audio_policy_configuration.xml
  do
    [ -e "${POLICY_ROOT}$f" ] && { POLICY_FILES="$POLICY_FILES ${POLICY_ROOT}$f"; [ -z "$POLICY" ] && POLICY="${POLICY_ROOT}$f"; }
  done
fi

APPLIED=no
MOUNTED_N=0
if [ -n "$POLICY_FILES" ]; then
  for f in $POLICY_FILES; do
    m="否"
    grep -q "$MARKER" "$f" 2>/dev/null && { m="是"; APPLIED=yes; MOUNTED_N=$((MOUNTED_N + 1)); }
    if awk -v t="$f" '$2==t{f=1}END{exit !f}' "$MOUNTS" 2>/dev/null; then bm="绑定挂载"; else bm="-"; fi
    printf '  %-46s 补丁:%s  %s\n' "$f" "$m" "$bm"
  done
  printf '补丁范围     : %s / %s 个策略文件\n' "$MOUNTED_N" "$(printf '%s' "$POLICY_FILES" | wc -w)"
  grep -h -o "dialect=[a-z]* | stock=[^ ]*" $POLICY_FILES 2>/dev/null | head -n1 | sed 's/^/生成标记     : /'
else
  printf '策略文件     : 未找到任何 XML 音频策略（本机可能是 Android 7 或更早）\n'
fi
printf 'audioserver  : %s\n' "$(getprop init.svc.audioserver)"
printf '模块目录     : '
for m in "${PROOT}/data/adb/modules/$MOD_ID" "${PROOT}/data/adb/modules_update/$MOD_ID"; do
  [ -d "$m" ] && printf '%s ' "$m"
done
printf '\n'
if [ -d "${PROOT}/data/adb/modules/op13_hifi_src_bypass" ]; then
  printf '! 注意       : 旧模块 op13_hifi_src_bypass 仍然装着 —— 两个模块不能同时\n'
  printf '               绑定挂载同一个策略文件，请卸载其中一个后重启。\n'
fi

# ============================================ 1b. which ports this ROM exposes
sec 1b "本机策略里被识别到的输出端口"
PORT_MAP="$STATE/portmap.txt"
: > "$PORT_MAP"
if [ -n "$POLICY_FILES" ]; then
  for f in $POLICY_FILES; do
    port_scan "${POLICY_ROOT:-}${f}" >> "$PORT_MAP"
  done
  for c in USB WIRED DIR MIX SPK; do
    n="$(names_of "$c")"
    printf '  %-6s : %s\n' "$c" "${n:-（无）}"
  done
else
  printf '  跳过\n'
fi
USB_PORTS="$(names_of USB)"
WIRED_PORTS="$(names_of WIRED)"
DIR_PORTS="$(names_of DIR)"
MIX_PORTS="$(names_of MIX)"
SPK_PORTS="$(names_of SPK)"
printf '\n  说明：USB 走通路上是 USB，WIRED 是 3.5mm/模拟，DIR 是 App 独占直通，\n'
printf '        MIX 是混音路径（混音率对齐作用于此），SPK 是扬声器/听筒。\n'

# -------------------------------------------------------------- SPK port scan
# Did the speaker / earpiece device port get pinned to CONFIG_SPK and topped
# out at CONFIG_SPKBITS?  We re-read the live XML (which is the bind-mounted
# patch file) and pick out the samplingRates + format attributes of every
# tag whose tagName / name carries "Speaker" or "Earpiece" -- the SPK class
# from the patcher's view covers all of those, including the empty-profile
# `Speaker Safe` variant that some ROMs ship; empty ports are silently dropped
# (a port with zero profiles has no rate set and no formats, so the verdict
# is meaningless for it).
SPK_PORT_SCAN="no"
SPK_VERDICT=""
if [ -n "$POLICY" ] && [ "$APPLIED" = yes ] 2>/dev/null; then
  SPK_PORT_SCAN="yes"
  # pull every tagName-bearing devicePort whose name looks like SPK; preserve
  # the order they appear in the file.  We scan in *devicePort block* units
  # because the opening tag may sit on its own line and start after a few
  # nested <profile> lines, and we want every profile's rate+bit attributed
  # to the right port.
  spk_lines="$(awk '
    BEGIN { in_dp = 0 }
    {
      if (!in_dp) {
        if ($0 ~ /<devicePort/) {
          tn = ""
          # tagName is the AOSP / OP13 QTI name; name is a generic QTI AIDL
          # fallback; type is the older AOSP HIDL fallback.  The first one
          # that matches wins, in that order.
          if (match($0, /tagName="[^"]*"/)) tn = substr($0, RSTART+9, RLENGTH-10)
          else if (match($0, /name="[^"]*"/)) tn = substr($0, RSTART+6, RLENGTH-7)
          else if (match($0, /type="AUDIO_DEVICE_OUT_[^"]*"/)) tn = substr($0, RSTART+21, RLENGTH-22)
          if (tn ~ /^[Ss]peaker$|^[Ee]arpiece$/) {
            in_dp = 1; print "PORT|" tn
          }
          # non-SPK devicePort: do NOT enter the block.  We rely on the next
          # <devicePort or </devicePort pattern in another file to bound it,
          # but since most ROMs only ever nest <profile> inside <devicePort>,
          # the boundary is the *closing* </devicePort -- so we stay out of
          # the block entirely.  This means a non-SPK devicePort can stretch
          # over many lines and we will simply not process its body, which
          # is exactly what we want.
        }
      } else {
        # inside a Speaker/Earpiece block -- collect profile attributes
        if (match($0, /samplingRates="[^"]*"/)) {
          s = substr($0, RSTART+15, RLENGTH-16); gsub(/,|;/, " ", s)
          print "RATE|" s
        }
        if ($0 ~ /format="AUDIO_FORMAT_PCM_16_BIT"/ || $0 ~ /pcmType="INT_16_BIT"/) print "BIT|16"
        if ($0 ~ /format="AUDIO_FORMAT_PCM_24_BIT_PACKED"/ || $0 ~ /pcmType="INT_24_BIT"/ || $0 ~ /pcmType="FIXED_Q_8_24"/) print "BIT|24"
        if ($0 ~ /format="AUDIO_FORMAT_PCM_32_BIT"/ || $0 ~ /pcmType="INT_32_BIT"/) print "BIT|32"
        if ($0 ~ /<\/devicePort>/) { print "ENDPORT"; in_dp = 0; cur = "" }
      }
    }
  ' "$POLICY" 2>/dev/null)"
  # per-port accumulators derived directly from the raw scan.  We do not
  # bother with a shell-side accumulator any more -- awk below gives us the
  # final per-port verdict in a single pass.
  SPK_INFO="$(printf '%s\n' "$spk_lines" | awk '
    BEGIN { cur=""; nm=0; nr=0; }
    /^PORT\|/ {
      if (cur != "" && nm > 0) {
        # collapse rates: only single-rate ports count
        if (nr == 1) {
          print cur "|" rates "|" has24 "|" has32
        } else {
          print cur "|MULTI|" has24 "|" has32
        }
      }
      cur = substr($0, index($0, "|") + 1)
      rates = ""; nm = 0; nr = 0; has24 = 0; has32 = 0
    }
    /^RATE\|/ {
      r = substr($0, index($0, "|") + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", r)
      rates = rates " " r
      nf = split(r, _ff)
      nm = nf
      nr = nf
    }
    /^BIT\|/ {
      b = substr($0, index($0, "|") + 1)
      if (b == "24") has24 = 1
      if (b == "32") has32 = 1
    }
    END {
      if (cur != "" && nm > 0) {
        if (nr == 1) {
          print cur "|" rates "|" has24 "|" has32
        } else {
          print cur "|MULTI|" has24 "|" has32
        }
      }
    }
  ')"
  # accumulate the verdict from SPK_INFO: pick the LARGEST single-rate port
  # (a port whose module pinned is the speaker port we care about; ports
  # left multi-rate get ignored as the module did not touch them)
  SPK_INFO_VERDICT="$(printf '%s\n' "$SPK_INFO" | awk -F'|' '
    $2 != "MULTI" && $2 != "" {
      if ($2 + 0 > max) {
        max = $2 + 0
        h24 = ($3 == 1) ? "yes" : "no"
        h32 = ($4 == 1) ? "yes" : "no"
        thePort = $1
      }
    }
    END {
      if (thePort == "") print "0|no|no"
      else printf "%d|%s|%s|%s\n", max, h24, h32, thePort
    }
  ')"
  SPK_MAX_RATE="$(printf '%s\n' "$SPK_INFO_VERDICT" | cut -d'|' -f1)"
  SPK_HAS24="$(printf '%s\n' "$SPK_INFO_VERDICT" | cut -d'|' -f2)"
  SPK_HAS32="$(printf '%s\n' "$SPK_INFO_VERDICT" | cut -d'|' -f3)"
  SPK_BIGGEST_PORT="$(printf '%s\n' "$SPK_INFO_VERDICT" | cut -d'|' -f4)"
  case "$CONFIG_SPKBITS" in
    16) want_24=no;  want_32=no  ;;
    24) want_24=yes; want_32=no  ;;
    32) want_24=yes; want_32=yes ;;
    *)  want_24=no;  want_32=no  ;;
  esac
  SPK_RATE_OK="no"; SPK_BITS_OK="no"
  if [ "$CONFIG_SPK" = auto ]; then
    SPK_RATE_OK="yes"
  else
    # numeric SPK_RATE: every pinned port must equal CONFIG_SPK; we already
    # filtered to single-rate ports above, so SPK_MAX_RATE is one rate only
    [ -n "$SPK_MAX_RATE" ] && [ "$SPK_MAX_RATE" = "$CONFIG_SPK" ] && SPK_RATE_OK="yes"
  fi
  if [ "$want_24" = "$SPK_HAS24" ] && [ "$want_32" = "$SPK_HAS32" ]; then
    SPK_BITS_OK="yes"
  fi
  case "$SPK_RATE_OK:$SPK_BITS_OK" in
    yes:yes) SPK_VERDICT="✅ 扬声器档位生效（采样率=${CONFIG_SPK} 位深上限=${CONFIG_SPKBITS}bit，最高活动端口=${SPK_BIGGEST_PORT:-?} @ ${SPK_MAX_RATE}Hz）" ;;
    yes:no)  SPK_VERDICT="⚠️ 扬声器采样率已钉到 ${CONFIG_SPK} Hz（最高活动端口 ${SPK_BIGGEST_PORT:-?}），但位深档未生效（实测 INT_24_BIT=${SPK_HAS24} INT_32_BIT=${SPK_HAS32}，期望 ${want_24}/${want_32}）" ;;
    no:yes)  SPK_VERDICT="⚠️ 扬声器位深档（${CONFIG_SPKBITS}bit）已生效，但采样率未钉到 ${CONFIG_SPK} Hz（实测端口最高采样率=${SPK_MAX_RATE:-?} Hz，最高活动端口=${SPK_BIGGEST_PORT:-?}）" ;;
    no:no)   SPK_VERDICT="❌ 扬声器档位未生效 —— 采样率钉到 ${CONFIG_SPK:-?} 失败（实测最高 ${SPK_MAX_RATE:-?} Hz），位深档也未对齐（实测 INT_24_BIT=${SPK_HAS24} INT_32_BIT=${SPK_HAS32}，期望 ${want_24}/${want_32}）" ;;
  esac
fi

# =============================================== 2. per-port ceilings (layer A)
sec 2 "生效文件里的上限（证据 A：配置层）"
if [ -n "$POLICY" ]; then
  printf '配置(config.conf) : 混音 %s Hz / 采样率上限 %s Hz / 位深上限 %s bit\n' \
    "${CONFIG_MIX:-?}" "${CONFIG_MAX:-?}" "${CONFIG_BITS:-?}"
  printf '\n%-30s %-12s %-14s\n' "端口" "最高采样率" "达配置上限?"
  for p in $DIR_PORTS; do
    b="$(mix_at "$POLICY" "$p")"
    printf '%-30s %-12s %-14s\n' "mixPort:$p" "$(printf '%s\n' "$b" | max_rate_of)" \
      "$(printf '%s\n' "$b" | has_rate x "${CONFIG_MAX:-0}")"
  done
  for p in $MIX_PORTS; do
    b="$(mix_at "$POLICY" "$p")"
    printf '%-30s %-12s %-14s\n' "mixPort:$p(混音)" "$(printf '%s\n' "$b" | max_rate_of)" \
      "$(printf '%s\n' "$b" | has_rate x "${CONFIG_MAX:-0}")"
  done
  for p in $USB_PORTS $WIRED_PORTS; do
    b="$(dev_at "$POLICY" "$p")"
    printf '%-30s %-12s %-14s\n' "dev:$p" "$(printf '%s\n' "$b" | max_rate_of)" \
      "$(printf '%s\n' "$b" | has_rate x "${CONFIG_MAX:-0}")"
  done

  printf '\n小尾巴/耳机端口的位深（已去掉注释，只算真正生效的）：\n'
  for p in $USB_PORTS $WIRED_PORTS; do
    b="$(dev_at "$POLICY" "$p")"
    live="$(printf '%s\n' "$b" | live_pcms)"
    [ -n "$live" ] || live="$(printf '%s\n' "$b" | live_fmts)"
    nb="$(printf '%s\n' "$b" | bits_of_port)"
    printf '  %-22s 生效: %-46s 最高 %s bit\n' "$p" "$live" "$nb"
    if [ -z "${CONFIG_BITS:-}" ]; then
      printf '  ->  %-19s config.conf 不可读，跳过期望比对\n' "$p"
    else
      case "$nb" in
        ''|0) printf '  ->  %-19s 端口里没读到位深 profile（常见于 mixPort 空壳，见 1b 说明）\n' "$p" ;;
        *)    if [ "$nb" -ge "${CONFIG_BITS:-0}" ] 2>/dev/null; then
                printf '  ->  %-19s 已达 BIT_DEPTH=%s 的上限  OK\n' "$p" "$CONFIG_BITS"
              else
                printf '  ->  %-19s 只有 %sbit，低于配置的 %sbit 上限（音源/App 请求更低，或档位没生效）\n' \
                       "$p" "$nb" "$CONFIG_BITS"
              fi ;;
      esac
    fi
  done
  # the highest live bit depth on the USB path is the reference the HAL will
  # pack a FLOAT / higher-bit stream into
  USB_POLICY_BITS=0
  for p in $USB_PORTS; do
    n="$(dev_at "$POLICY" "$p" | bits_of_port)"
    [ "${n:-0}" -gt "$USB_POLICY_BITS" ] 2>/dev/null && USB_POLICY_BITS="$n"
  done
else
  printf '跳过\n'
fi

# ====================== 3. audioserver's view (layer B: did it read the patch?)
sec 3 "系统侧看到的直通端口（证据 B：audioserver 是否读到了补丁）"
# NEVER put a dumpsys dump in a shell variable and printf it: the dump easily
# exceeds Linux's 128 KB MAX_ARG_STRLEN, the error goes to stderr only, and the
# symptom is "this whole section is blank" which looks like a permission
# problem.  Redirect to a file and analyse the file.
DUMPF=/data/local/tmp/.hifi_probe_dump.txt
dumpsys media.audio_policy > "$DUMPF" 2>/dev/null
if [ ! -s "$DUMPF" ]; then
  printf 'dumpsys 无输出（或者被 SELinux 拦了）\n'
else
  printf 'dump 大小 : %s 行（写入 %s 做分析，脚本结束会删掉）\n' \
    "$(wc -l < "$DUMPF" 2>/dev/null)" "$DUMPF"
  printf 'Config source : %s\n' "$(cat "$DUMPF" | sed -n 's/^ *Config source: *//p' | head -n1)"

  for p in $DIR_PORTS $MIX_PORTS "$(printf '%s' $USB_PORTS | cut -d' ' -f1)"; do
    [ -n "$p" ] || continue
    dmax="$(cat "$DUMPF" \
      | awk -v nm="\"$p\"" '$0 ~ nm {f=1} f && /";[[:space:]]*0x/ && $0 !~ nm {exit} f' \
      | sed -n 's/.*sampling rates: *//p' | tr ',' '\n' | tr -d ' ' | grep -E '^[0-9]+$' | sort -n | tail -n1)"
    printf '%-28s 运行时上限 : %s\n' "$p" "${dmax:-未取到}"
    if [ -n "${dmax:-}" ] && [ -n "${CONFIG_MAX:-}" ]; then
      if [ "$dmax" -eq "$CONFIG_MAX" ] 2>/dev/null; then
        printf '  -> 与配置的 %s Hz 一致：audioserver 已读到补丁，B 层生效\n' "$CONFIG_MAX"
      else
        hi="$(mix_at "$POLICY" "$p" | max_rate_of)"
        if [ -n "$hi" ] && [ "$dmax" -eq "$hi" ] 2>/dev/null; then
          printf '  -> 与生效文件里的上限(%s)一致，但它和配置的 %s Hz 不同\n' "$hi" "$CONFIG_MAX"
        else
          printf '  -> %s 与配置的 %s Hz 不符 —— 可能没生效，或被 ROM 重挂顶掉了\n' "$dmax" "$CONFIG_MAX"
        fi
      fi
    fi
  done

  printf '\nUSB 输出端口的运行时能力（位深真正生效的地方）：\n'
  cat "$DUMPF" | awk -v names="$USB_PORTS" '
    BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) want["\"" a[i] "\""] = 1 }
    /Port ID: *[0-9]+; "/ { u = 0; for (k in want) if (index($0, k) > 0) u = 1 }
    u && /^[[:space:]]*[0-9]+\.[[:space:]]*Port ID:/ && !/Port ID: *[0-9]+; "/ { u = 0 }
    u && (n2 = 1) { print "      " $0 }
  ' 2>/dev/null | head -n 28

  printf '\n"可用输出设备"里的 USB 声卡（有它才说明小尾巴被系统认到）：\n'
  cat "$DUMPF" | awk -v names="$USB_PORTS" '
    BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) want["\"" a[i] ";"] = 1 }
    /Available output devices/ { av = 1 }
    av && /Available input devices/ { av = 0 }
    av {
      hit = 0
      for (k in want) if (index($0, k) > 0) hit = 1
      if (hit) { u = 1; print "  ---- 找到 USB 输出 ----"; print "  " $0; next }
      if (u && /^[[:space:]]*[0-9]+\.[[:space:]]*Port ID:/) u = 0
      if (u) print "  " $0
    }
  ' 2>/dev/null
fi
D_DUMP_OK=no; [ -s "$DUMPF" ] && D_DUMP_OK=yes
rm -f "$DUMPF" 2>/dev/null

# ============================== 4. DAC advertised capability (layer C)
sec 4 "USB 声卡的声明能力（证据 C：DAC 声明支持什么 —— 不是此刻在跑什么）"
FOUND_USB_CARD=""
if [ ! -d "$CARD_ROOT" ]; then
  printf '! %s 不存在（内核未开 SND_PROC_FS），无法读取\n' "$CARD_ROOT"
else
  if [ -r "$CARD_ROOT/cards" ]; then
    printf '%s\n' "--- /proc/asound/cards ---"
    sed 's/^/  /' "$CARD_ROOT/cards"
  fi
  for c in "$CARD_ROOT"/card[0-9]*; do
    [ -d "$c" ] || continue
    n="${c##*card}"
    st="$c/stream0"
    [ -r "$st" ] || continue
    head1="$(head -n1 "$st")"
    case "$head1" in
      *' at usb-'*) kind="USB" ;;
      *)            kind="内置/其它" ;;
    esac
    printf '\n  card%s  [%s]  %s\n' "$n" "$kind" "$head1"
    if [ "$kind" = "USB" ]; then
      FOUND_USB_CARD="$n"
      pb="$(sed -n '/Playback:/,/Capture:/p' "$st" 2>/dev/null)"
      printf '    Playback Status : %s\n' "$(printf '%s\n' "$pb" | sed -n 's/^ *Status: *//p' | head -n1)"
      printf '%s\n' "$pb" | awk '
        /Altset/  { a=$0; sub(/^[ \t]+/,"",a) }
        /Format:/ { f=$0; sub(/^[ \t]+/,"",f) }
        /Rates:/  { r=$0; sub(/^[ \t]+/,"",r); printf "    %-10s %-16s %s\n", a, f, r }
      '
      printf '    ↑ 这些 Rates 只是 DAC 声明的能力上限，不代表此刻在跑\n'
    fi
  done
fi
if [ -z "$FOUND_USB_CARD" ]; then
  printf '\n! %s 里没有 USB 音频声卡。可能原因（按可能性排序）：\n' "$CARD_ROOT"
  printf '  1) 小尾巴被某个 App 用自带 USB 驱动抢走了（"独占"的另一种实现）。\n'
  printf '     内核 snd-usb-audio 不绑定该设备、也就不会建 ALSA 声卡，\n'
  printf '     但 dumpsys 里仍可能残留它的描述符 —— 下面 4b 段的绑定情况可判定。\n'
  printf '  2) USB-C 接触不良 / 没插到底 / 转接头不合规，设备没枚举成功。\n'
  printf '  3) 该耳机是【模拟】Type-C 或 3.5mm（吃手机自带 codec，走 WIRED 通道），\n'
  printf '     本来就不会出现在这里。本机 WIRED 端口：%s\n' "${WIRED_PORTS:-无}"
fi

# -------------------------------- 4b. kernel side: who owns the USB audio ifaces
# Count interfaces, never `ls -l ... | grep -c ' -> '` -- that also matches the
# `module -> ...` symlink, so it is always >= 1 and has already produced a
# wrong "driver binding is fine" conclusion once.
printf '\n--- 4b. 内核侧：USB 音频接口归谁 ---\n'
printf '  snd-usb-audio = 内核 ALSA 接管（正常，声音走 Android 音频栈）\n'
printf '  usbfs         = 被某个进程独占直连（App 自带 USB 驱动，绕过整个音频栈）\n'
printf '  （无 driver）  = 没有驱动，谁都放不出声，拔插一次即可恢复\n\n'
USB_USBFS=""
for drv in /sys/bus/usb/drivers/*; do
  dn="$(basename "$drv")"
  ifaces="$(ls "$drv" 2>/dev/null | grep ':' | tr '\n' ' ' | sed 's/ *$//')"
  [ -n "$ifaces" ] || continue
  n="$(printf '%s' "$ifaces" | wc -w)"
  printf '  %-14s 绑定 %s 个接口: %s\n' "$dn" "$n" "$ifaces"
  [ "$dn" = "usbfs" ] && USB_USBFS="$ifaces"
done
SND_N="$(ls /sys/bus/usb/drivers/snd-usb-audio/ 2>/dev/null | grep -c ':')"
USBFS_N="$(ls /sys/bus/usb/drivers/usbfs/ 2>/dev/null | grep -c ':')"
printf '\n  snd-usb-audio 绑定接口数 : %s\n' "${SND_N:-0}"
printf '  usbfs         绑定接口数 : %s\n' "${USBFS_N:-0}"
printf '  ALSA 声卡（/sys/class/sound 的 card*）: %s 张\n' \
  "$(ls /sys/class/sound/ 2>/dev/null | grep -c '^card')"
if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
  printf '  >>> 结论：小尾巴的音频接口被 usbfs 接管了 —— 音频【绕开了 Android 音频栈】，\n'
  printf '      本模块（改的是 audio_policy 配置）在这条路径上完全不起作用。\n'
  printf '      关掉播放器的"独占 USB"，然后【拔插一次】小尾巴，让内核把驱动抢回来。\n'
elif [ "${SND_N:-0}" -gt 0 ] 2>/dev/null; then
  printf '  >>> 结论：内核 ALSA 已接管，声音走 Android 音频栈，本模块在链路上。\n'
else
  printf '  >>> 结论：音频接口当前【没有驱动】—— 通常是刚被"独占"释放过。\n'
  printf '      拔插一次小尾巴即可让 snd-usb-audio 重新绑定。\n'
fi

# ============================ 5. what was actually negotiated (layer D)
sec 5 "此刻真正协商出来的频率与位深（证据 D：决定性）"
printf '请在【正在播放高解析音乐】的时候看这一段。\n\n'
ANY_OPEN=no
PCM_DIRS=0
PCM_OPEN_N=0
NOTE_RUN=no
for pcm in "$CARD_ROOT"/card[0-9]*/pcm*c "$CARD_ROOT"/card[0-9]*/pcm*p; do
  [ -d "$pcm" ] || continue
  PCM_DIRS=$((PCM_DIRS + 1))
  for sub in "$pcm"/sub*; do
    [ -d "$sub" ] || continue
    hp="$(cat "$sub/hw_params" 2>/dev/null)"
    stt="$(cat "$sub/status" 2>/dev/null)"
    case "$hp" in
      *closed*) continue ;;
      "") continue ;;
    esac
    ANY_OPEN=yes
    PCM_OPEN_N=$((PCM_OPEN_N + 1))
    printf '  ● /proc/asound/%s  ——  正在使用\n' "${pcm#$CARD_ROOT/}"
    printf '%s\n' "$hp" | sed -n 's/^ *\(access\|format\|subformat\|channels\|rate\) *: *\(.*\)/      \1 : \2/p'
    opid="$(printf '%s\n' "$stt" | sed -n 's/^ *owner_pid *: *//p' | head -n1)"
    printf '      state       : %s\n' "$(printf '%s\n' "$stt" | sed -n 's/^ *state: *//p' | head -n1)"
    printf '      owner_pid   : %s  (%s)\n' "${opid:-?}" "$(proc_of "${opid:-}")"
    rate="$(printf '%s\n' "$hp" | sed -n 's/^ *rate: *\([0-9]*\).*/\1/p' | head -n1)"
    case "$rate" in
      "")            : ;;
      *)             printf '      >>> 当前协商频率：%s Hz%s\n' "$rate" \
                       "$([ -n "${CONFIG_MAX:-}" ] && [ "$rate" -ge "${CONFIG_MAX:-0}" ] 2>/dev/null && echo '（已达配置上限）' || echo '')" ;;
    esac
    fmtv="$(printf '%s\n' "$hp" | sed -n 's/^ *format *: *//p' | head -n1)"
    sbits="$(printf '%s' "$fmtv" | sed -n 's/^S\([0-9]*\)_.*/\1/p')"
    if [ -n "$sbits" ]; then
      want_b="${CONFIG_BITS:-32}"
      printf '      >>> 真正协商出的位深：%s  (%s bit)\n' "$fmtv" "$sbits"
      if [ "$sbits" -ge "$want_b" ] 2>/dev/null; then
        printf '      >>> 已达到配置的 %sbit 位深上限：模块的位深档位生效\n' "$want_b"
      else
        printf '      >>> 只有 %sbit，低于配置的 %sbit 上限\n' "$sbits" "$want_b"
        printf '          （可能是音源位深本来更低、App 没申请高解析、或档位没生效）\n'
      fi
    fi
    case "$(proc_of "${opid:-}")" in
      *audioserver*) NOTE_MODE="android" ;;
      *) [ -n "${opid:-}" ] && NOTE_MODE="app" ;;
    esac
    NOTE_RUN=yes
    printf '\n'
  done
done

# --- three-state verdict: "detection impossible" is not "not running" --------
if [ "$PCM_DIRS" = 0 ]; then
  D_VERDICT="D1"
  if [ "${D_DUMP_OK:-}" = yes ]; then
    printf '  【D1】/proc/asound 观察通道本机不可用（0 个 pcm 目录，内核未导出）。\n'
    printf '  → 这只是观察通道缺失，与模块是否生效无关；链路证据已由下方 5b/5c\n'
    printf '    完整捕获 —— 直接看那两段的结论即可，此条可忽略。\n'
  else
    printf '  【D1 判定】在 %s 下找到 0 个 pcm 目录 —— 本机内核没有导出\n' "$CARD_ROOT"
    printf '  /proc/asound/.../pcm*/sub* 这棵树。这是【内核没开这条观察通道】，\n'
    printf '  不是模块没生效，也不是检测脚本的问题 —— 改多少版结果都一样。\n'
    printf '  → 本机 D 层请以下面 5b 段（dumpsys，不依赖 /proc）为准。\n'
  fi
elif [ "$ANY_OPEN" = no ]; then
  D_VERDICT="D2"
  printf '  【D2 判定】找到 %s 个 pcm 目录，此刻全部 closed —— ALSA 上没有任何流。\n' "$PCM_DIRS"
  printf '  两种可能：\n'
  printf '    a) 跑检测的时候音乐是【暂停/停止】状态 → 开始播放并保持，再跑一次；\n'
  printf '    b) 正在播放，但音频被播放器自带 USB 驱动（独占）接管 —— 没经过 ALSA，\n'
  printf '       结合第 4b 段（usbfs 绑定数）和 5c 段的 App 判定确认。\n'
else
  D_VERDICT="D3"
  printf '  【D3 判定】有 %s 条 PCM 流处于打开状态，明细如上。\n' "$PCM_OPEN_N"
fi

# --- 5b. what dumpsys says the audio is routed to right now ------------------
printf '\n--- 5b. 当前音频路由（从 dumpsys 读，不需要 root；D1/D2 状态下以这段为准）---\n'
D2=/data/local/tmp/.hifi_probe_dump2.txt
USBF=/data/local/tmp/.hifi_probe_usb.txt
USBF_ACTIVE=/data/local/tmp/.hifi_probe_usb_active.txt
dumpsys media.audio_policy > "$D2" 2>/dev/null
USB_REC_N=0
USB_ACTIVE_N=0
USB_DIRECT=no
USB_MIXED=no
USB_HIFI=no
TGT_SEEN=no
ACT_UID=""; ACT_FMT=""; ACT_RATE=""; ACT_NAME=""
OUT_CHAN=""; OUT_FMT=""; OUT_RATE=""; OUT_BITS=""

uid2pkg() {
  u="$1"
  [ -n "$u" ] || return 0
  p="$(awk -v u="$u" '$2==u{print $1; exit}' /data/system/packages.list 2>/dev/null)"
  if [ -n "$p" ]; then printf '%s' "$p"; else printf 'uid:%s' "$u"; fi
}
app_name_of() {
  case "$1" in
    com.netease.cloudmusic*)  printf '网易云音乐' ;;
    com.tencent.qqmusic*)     printf 'QQ音乐' ;;
    com.hiby.music*|com.hiby*) printf '海贝音乐' ;;
    com.maxmpz.audioplayer*)  printf 'Poweramp' ;;
    com.lonelycatgames*)      printf 'UAPP' ;;
    com.apple.android.music)  printf 'Apple Music' ;;
    *)                        printf '' ;;
  esac
}
# FLOAT is the *app-side container*; what actually goes out on the wire is
# bounded by the highest bit depth the policy leaves enabled on the USB port.
bits_of_fmt() {
  case "$1" in
    *FLOAT*)
      case "${USB_POLICY_BITS:-0}" in
        32) printf 'float(32bit)' ;;
        24) printf '24bit (float 容器)' ;;
        16) printf '16bit (float 容器)' ;;
        *)  printf 'float 容器' ;;
      esac ;;
    *32_BIT*)      printf '32bit' ;;
    *8_24_BIT*|*24_BIT*) printf '24bit' ;;
    *16_BIT*)      printf '16bit' ;;
    *)             printf '未知位深' ;;
  esac
}
# channel name -- resolved against THIS phone's port names, not a fixed list
chan_of() {
  p="$1"
  for d in $DIR_PORTS;  do [ "$d" = "$p" ] && { printf '直通 %s' "$p"; return; } done
  for d in $MIX_PORTS;  do [ "$d" = "$p" ] && { printf '混音 %s' "$p"; return; } done
  case "$p" in
    *hifi*|*HiFi*) printf 'HiFi 通道 %s' "$p"; return ;;
  esac
  printf 'USB 输出 %s' "$p"
}
if [ ! -s "$D2" ]; then
  printf '  dumpsys 无输出\n'
else
  printf '  正在活动的输出数（Global active count > 0）: %s\n' \
    "$(grep -c 'Global active count: [1-9]' "$D2" 2>/dev/null)"

  printf '  AudioTrack 客户端（谁在放、申请了什么格式/采样率，uid 已解析成包名）：\n'
  awk '/I\/O handle:/{c=0} /AudioTrack clients/{c=1} c && /uid [0-9]+; State:/{print "T|"$0} c && /AUDIO_FORMAT/{print "F|"$0}' "$D2" 2>/dev/null \
    | sed -n '1,40p' \
    | while IFS='|' read -r k line; do
        case "$k" in
          T) uid="$(printf '%s' "$line" | sed -n 's/.*uid \([0-9]*\).*/\1/p')"
             printf '    %s\n' "$line"
             [ -n "$uid" ] && printf '        └ uid %s = %s\n' "$uid" "$(uid2pkg "$uid")" ;;
          F) printf '        %s\n' "$line" ;;
        esac
      done

  # route records that go to USB: split into "N. Port ID:" blocks and keep the
  # ones mentioning AUDIO_DEVICE_OUT_USB.  The *active* ones are written to a
  # separate file, because a standby hifi/direct record also names a USB device
  # and would otherwise be mis-read as "playing through the passthrough".
  awk -v act="$USBF_ACTIVE" '
    /^[[:space:]]*Outputs \([0-9]+\)/ { o=1; next }
    o && /^[[:space:]]*Inputs \([0-9]+\)/ { o=0 }
    o && /^[[:space:]]*[0-9]+\.[[:space:]]*Port ID:/ {
      if (rec != "" && rec ~ /AUDIO_DEVICE_OUT_USB/) {
        print rec "\n==END=="
        if (rec ~ /Global active count: [1-9]/) print rec > act
      }
      rec=$0; next }
    o && rec != "" { rec = rec "\n" $0 }
    END {
      if (rec != "" && rec ~ /AUDIO_DEVICE_OUT_USB/) {
        print rec "\n==END=="
        if (rec ~ /Global active count: [1-9]/) print rec > act
      }
    }
  ' "$D2" > "$USBF" 2>/dev/null

  USB_REC_N="$(grep -c '^==END==$' "$USBF" 2>/dev/null)"
  case "$USB_REC_N" in ''|*[!0-9]*) USB_REC_N=0 ;; esac
  USB_ACTIVE_N="$(awk '/Global active count: [1-9]/{n++} END{print n+0}' "$USBF" 2>/dev/null)"
  case "$USB_ACTIVE_N" in ''|*[!0-9]*) USB_ACTIVE_N=0 ;; esac

  for d in $DIR_PORTS; do grep -q "\"$d\"" "$USBF_ACTIVE" 2>/dev/null && USB_DIRECT=yes; done
  for m in $MIX_PORTS; do grep -q "\"$m\"" "$USBF_ACTIVE" 2>/dev/null && USB_MIXED=yes; done
  grep -q 'hifi' "$USBF_ACTIVE" 2>/dev/null && USB_HIFI=yes

  # ----------------------------------------------------------------- 5b+
  # ALSO scan every active output (regardless of USB) and bucket its device
  # type so we can answer "is anything at all playing?" when no DAC is plugged
  # in.  v1.9 [7] segment used to incorrectly warn "no audio in playback"
  # while music apps were playing through the loudspeaker (no DAC connected).
  # Two passes:
  #   (a) dumpsys media.audio_policy (when it has the classic Outputs section)
  #   (b) dumpsys audio -- AudioPlaybackConfiguration.state:started counts, plus
  #       the AudioSystemAdapter device cache which lists every routable device
  # Buckets we care about:
  #   SPK_ACTIVE_N    -> SPEAKER (any flag combo, excluding SAFE)
  #   EARPIECE_ACTIVE_N -> EARPIECE
  #   WIRED_ACTIVE_N  -> WIRED_*
  SPK_ACTIVE_N=0; EARPIECE_ACTIVE_N=0; WIRED_ACTIVE_N=0
  PHONE_ACTIVE_N=0  # loudspeaker + earpiece combined (the user's phone output)
  MEDIA_PLAYING_N=0  # count of started USAGE_MEDIA AudioPlaybackConfigurations
  DUMP_B="/data/local/tmp/.hifi_probe_dump_audio.txt"
  dumpsys audio 2>/dev/null > "$DUMP_B"
  # (a) dumpsys media.audio_policy -- still useful on QTI/AIDL where it's not empty
  awk -v d2="$D2" '
    /^[[:space:]]*Outputs \([0-9]+\)/ { o=1; next }
    o && /^[[:space:]]*Inputs \([0-9]+\)/ { o=0 }
    o && /^[[:space:]]*[0-9]+\.[[:space:]]*Port ID:/ {
      if (rec != "") {
        if (rec ~ /Global active count: [1-9]/) print rec "\n==END=="
      }
      rec=$0; next
    }
    o && rec != "" { rec = rec "\n" $0 }
    END { if (rec != "" && rec ~ /Global active count: [1-9]/) print rec "\n==END==" }
  ' "$D2" 2>/dev/null | awk '
    /^==END==$/ { if (rec != "") process(); rec=""; next }
    { rec = rec (rec != "" ? "\n" : "") $0 }
    END { if (rec != "") process() }
    function process() {
      ty = ""
      if (match(rec, /type:[A-Za-z_]+/)) ty = substr(rec, RSTART+5, RLENGTH-5)
      if (ty == "") return
      if (ty ~ /SPEAKER/ && ty !~ /SAFE/) spk_n++
      else if (ty ~ /EARPIECE/) epc_n++
      else if (ty ~ /WIRED_/) wired_n++
    }
    END {
      print "SPK=" spk_n + 0
      print "EARPIECE=" epc_n + 0
      print "WIRED=" wired_n + 0
    }
  ' > /data/local/tmp/.hifi_probe_audio_buckets.txt 2>/dev/null
  # (b) dumpsys audio -- scan all places that hint at the routing target:
  #     * AudioPlaybackConfiguration.state:started + usage=USAGE_MEDIA      -> app
  #       is playing media right now (regardless of output device)
  #     * AudioSystemAdapter.mDevicesForAttrCache entries with type:speaker /
  #       earpiece -> these are the device caches the system will route USAGE_MEDIA
  #       to when no DAC is connected; if they say "speaker" we know the
  #       loudspeaker is the live target even if media.audio_policy is empty.
  MEDIA_PLAYING_N="$(awk '
    /AudioPlaybackConfiguration .*state:started/ {
      block = $0
      next_line = 1
      while (next_line && getline nxt > 0) {
        if (nxt ~ /state:paused/) { next_line = 0; break }
        if (nxt ~ /usage=USAGE_MEDIA/) { media_n++; next_line = 0; break }
      }
    }
    END { print media_n + 0 }
  ' "$DUMP_B" 2>/dev/null)"
  case "$MEDIA_PLAYING_N" in ''|*[!0-9]*) MEDIA_PLAYING_N=0 ;; esac
  # also count any active speaker/earpiece/wired device routed by the system
  AUDIO_ROUTE_ACTIVE="$(awk '
    /AudioDeviceAttributes:/ {
      # the next line(s) describe the routing: type:speaker / earpiece / wired_*
      t = ""
      if (getline ln > 0) {
        if (match(ln, /type:[A-Za-z_]+/)) t = substr(ln, RSTART+5, RLENGTH-5)
        else t = ""
      }
      if (t == "") next
      if (t ~ /SPEAKER/ && t !~ /SAFE/) spk_n++
      else if (t ~ /EARPIECE/) epc_n++
      else if (t ~ /WIRED_/) wired_n++
    }
    END { print spk_n+0, epc_n+0, wired_n+0 }
  ' "$DUMP_B" 2>/dev/null)"
  AUDIO_SPK=$(echo "$AUDIO_ROUTE_ACTIVE" | awk '{print $1}')
  AUDIO_EPC=$(echo "$AUDIO_ROUTE_ACTIVE" | awk '{print $2}')
  AUDIO_WIRED=$(echo "$AUDIO_ROUTE_ACTIVE" | awk '{print $3}')
  case "$AUDIO_SPK" in ''|*[!0-9]*) AUDIO_SPK=0 ;; esac
  case "$AUDIO_EPC" in ''|*[!0-9]*) AUDIO_EPC=0 ;; esac
  case "$AUDIO_WIRED" in ''|*[!0-9]*) AUDIO_WIRED=0 ;; esac
  if [ -r /data/local/tmp/.hifi_probe_audio_buckets.txt ]; then
    A_SPK="$(sed -n 's/^SPK=//p' /data/local/tmp/.hifi_probe_audio_buckets.txt | head -1)"
    A_EPC="$(sed -n 's/^EARPIECE=//p' /data/local/tmp/.hifi_probe_audio_buckets.txt | head -1)"
    A_WIRED="$(sed -n 's/^WIRED=//p' /data/local/tmp/.hifi_probe_audio_buckets.txt | head -1)"
    case "$A_SPK" in ''|*[!0-9]*) A_SPK=0 ;; esac
    case "$A_EPC" in ''|*[!0-9]*) A_EPC=0 ;; esac
    case "$A_WIRED" in ''|*[!0-9]*) A_WIRED=0 ;; esac
    SPK_ACTIVE_N=$(( ${A_SPK:-0} > ${AUDIO_SPK:-0} ? ${A_SPK:-0} : ${AUDIO_SPK:-0} ))
    EARPIECE_ACTIVE_N=$(( ${A_EPC:-0} > ${AUDIO_EPC:-0} ? ${A_EPC:-0} : ${AUDIO_EPC:-0} ))
    WIRED_ACTIVE_N=$(( ${A_WIRED:-0} > ${AUDIO_WIRED:-0} ? ${A_WIRED:-0} : ${AUDIO_WIRED:-0} ))
  fi
  PHONE_ACTIVE_N=$((SPK_ACTIVE_N + EARPIECE_ACTIVE_N))
  printf '  本机扬声器活动输出 : %s 条（speaker %s / earpiece %s / wired %s / 媒体 started 流 %s）\n' \
    "$PHONE_ACTIVE_N" "$SPK_ACTIVE_N" "$EARPIECE_ACTIVE_N" "$WIRED_ACTIVE_N" "$MEDIA_PLAYING_N"
  rm -f /data/local/tmp/.hifi_probe_audio_buckets.txt 2>/dev/null
  rm -f "$DUMP_B" 2>/dev/null

  printf '  路由到 USB 的输出（共 %s 条，其中活动的 %s 条；原文）：\n' "$USB_REC_N" "$USB_ACTIVE_N"
  grep -v '^==END==$' "$USBF" 2>/dev/null | sed 's/^/    /' | head -40
  if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
    printf '    ⚠ usbfs 正接管小尾巴（4b 段）：内核里这张 USB 声卡已消失，\n'
    printf '      上面这些"活动输出"是 HAL 缓存的幽灵路由 / App 伴生流 —— 不代表真实路径。\n'
  fi
  printf '\n  判读：出现 AUDIO_DEVICE_OUT_USB_HEADSET + 期望的 AUDIO_FORMAT/采样率 = 链路通；\n'
  printf '        这里一条 USB 输出都没有 = 音频没往小尾巴送（或被 App 自带驱动抢走）。\n'

  # ================================================== 5c. channel verdict
  printf '\n--- 5c. 链路判定（按播放器）---\n'
  for u in $(awk '/AudioTrack clients/{c=1} c && /uid [0-9]+; State:/{print}' "$D2" 2>/dev/null \
             | sed -n 's/.*uid \([0-9]*\).*/\1/p' | sort -u); do
    p="$(uid2pkg "$u")"
    nm="$(app_name_of "$p")"
    [ -n "$nm" ] || continue
    TGT_SEEN=yes
    printf '  · 检测到【%s】有播放活动（%s）—— 它申请的格式/采样率见上面客户端段\n' "$nm" "$p"
  done
  [ "$TGT_SEEN" = yes ] || printf '  · 本次 dump 里没有检测到常见高解析播放器的播放活动\n'

  printf '\n  链路判定：\n'
  if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
    # the usbfs evidence outranks the dumpsys active outputs
    printf '    ✓✓ 小尾巴的接口被 usbfs 接管（第 4b 段：%s 条）—— 播放器【自带 USB 驱动独占中】。\n' "${USBFS_N:-0}"
    printf '      这就是「独占 USB 输出」生效的形态：音乐由 App 自己的驱动 bit-perfect 直连 DAC，\n'
    printf '      完全绕过 Android 音频栈 —— 本模块在此路径上【既不参与也不限制】。\n'
    printf '      此刻 dumpsys 里的活动 USB 输出是幽灵路由（内核声卡已消失），\n'
    printf '      它显示直通还是混音都【不算数】，真实路径以本条 usbfs 判定为准。\n'
    printf '      想回到 Android 音频栈：关掉播放器的独占开关，然后拔插一次小尾巴。\n'
  elif [ "$USB_ACTIVE_N" -gt 0 ] 2>/dev/null; then
    if [ "$USB_DIRECT" = yes ]; then
      printf '    ✓ 有活动输出走【直通 %s】送往小尾巴 —— 模块策略在链路上。\n' "${DIR_PORTS:-direct}"
      printf '      此时位深/采样率看 D3 明细（有流时）或输出记录里的协商格式。\n'
    elif [ "$USB_HIFI" = yes ]; then
      printf '    ✓ 有活动输出走【hifi 专用输出】送往小尾巴 —— 这是厂商为高解析 AudioTrack\n'
      printf '      开的专用输出，能力按 DAC 动态上报协商。输出记录里的 AUDIO_FORMAT/采样率\n'
      printf '      就是真实送达小尾巴的规格（如 24_BIT_PACKED; 96000 = 24bit/96k）。\n'
    elif [ "$USB_MIXED" = yes ]; then
      printf '    ▲ 有活动输出走【混音路径 %s】送往小尾巴：\n' "${MIX_PORTS:-deep_buffer/low_latency}"
      printf '      混音路径的位深与采样率由【App 自己的 AudioTrack 请求】决定 ——\n'
      printf '      App 申请 16bit/48k 就只会是 16bit/48k，这不是模块能改的。\n'
      printf '      模块对混音路径的作用只是"混音率对齐免重采样"，给不了 24bit。\n'
    else
      printf '    ? 有 USB 输出但记录里认不出端口名，按 5b 原文里的格式行判读。\n'
    fi
  else
    printf '    ✗ 此刻没有任何输出路由到小尾巴：\n'
    if [ "$TGT_SEEN" = yes ]; then
      printf '      目标 App 有播放活动，但没有任何输出路由到 USB ——\n'
      printf '      可能在走扬声器/蓝牙，或独占申请失败后回退到了内置通道。\n'
    else
      printf '      检测时没有 App 在向小尾巴播放（暂停/停止？）→ 播放中重测。\n'
    fi
  fi

  printf '\n  "感觉不到提升"的常见机制原因（不是模块坏了）：\n'
  printf '   · App【不开】独占 = 走 Android 音频栈，高解析请求经直通/HiFi 输出送出 ——\n'
  printf '     模块在链路上，可识别、可干预。【开】独占 = 自带 usbfs 驱动直连 DAC，\n'
  printf '     模块在链路外（bit-perfect，与本模块无关）。\n'
  printf '   · 没有独占开关的播放器永远走混音路径 —— 位深/采样率由它自己的请求决定，\n'
  printf '     模块能给的只有混音率对齐（免重采样）。\n'
  printf '   · USB 小尾巴的瓶颈往往不是采样率而是位深：原厂常用采样率已到 192k，\n'
  printf '     却只给 16bit。本模块补的 24/32bit 才是主要收益。\n'

  # ------------------------------------------------- 速览数据采集（第 7 段用）
  act_lines="$(awk '/AudioTrack clients/{c=1} c && /uid [0-9]+; State: Active/{f=1; print; next} f && /AUDIO_FORMAT/{print; exit}' "$D2" 2>/dev/null)"
  ACT_UID="$(printf '%s\n' "$act_lines" | sed -n 's/.*uid \([0-9]*\).*/\1/p' | head -n1)"
  ACT_FMT="$(printf '%s\n' "$act_lines" | sed -n 's/.*\(AUDIO_FORMAT_[A-Z0-9_]*\).*/\1/p' | tail -n1)"
  ACT_RATE="$(printf '%s\n' "$act_lines" | sed -n 's/.*AUDIO_FORMAT_[A-Z0-9_]*; *\([0-9]*\).*/\1/p' | tail -n1)"
  if [ -n "$ACT_UID" ]; then
    act_pkg="$(uid2pkg "$ACT_UID")"
    act_nm="$(app_name_of "$act_pkg")"
    if [ -n "$act_nm" ]; then ACT_NAME="$act_nm(${act_pkg})"; else ACT_NAME="$act_pkg"; fi
  fi
  if [ "$USB_ACTIVE_N" -gt 0 ] 2>/dev/null; then
    out_lines="$(awk '
      /^[[:space:]]*[0-9]+\.[[:space:]]*Port ID:/ { inrec=1; iop=""; fmt="" }
      inrec && /IOProfile/ && iop == "" { iop=$0 }
      inrec && /AUDIO_FORMAT_[A-Z0-9_]*; *[0-9]+/ && fmt == "" { fmt=$0 }
      inrec && /Global active count: [1-9]/ { print iop; print fmt; exit }
    ' "$USBF" 2>/dev/null)"
    OUT_CHAN="$(printf '%s\n' "$out_lines" | sed -n 's/.*IOProfile *name: *\([^;]*\).*/\1/p' | head -n1)"
    OUT_FMT="$(printf '%s\n' "$out_lines" | sed -n 's/.*\(AUDIO_FORMAT_[A-Z0-9_]*\).*/\1/p' | tail -n1)"
    OUT_RATE="$(printf '%s\n' "$out_lines" | sed -n 's/.*AUDIO_FORMAT_[A-Z0-9_]*; *\([0-9]*\).*/\1/p' | tail -n1)"
    OUT_BITS="$(bits_of_fmt "$OUT_FMT")"
    [ -n "$OUT_CHAN" ] && OUT_CHAN="$(chan_of "$OUT_CHAN")"
  fi
fi
rm -f "$D2" "$USBF" "$USBF_ACTIVE" 2>/dev/null

# ================== 6. who holds the dongle
sec 6 "谁占着小尾巴（判断本模块是否在链路上）"
USB_LS="$(ls -l /proc/[0-9]*/fd 2>/dev/null | grep '/dev/bus/usb' || true)"
if [ -z "$USB_LS" ]; then
  printf '  没有进程持有 /dev/bus/usb 设备节点。\n'
  printf '  注意：/proc/PID/fd 可能被 hidepid 限制，这里"空"不一定代表真的没人占。\n'
  printf '  交叉验证请看第 4b 段：内核有没有把 snd-usb-audio 绑到 USB 音频设备上。\n'
else
  printf '  持有 /dev/bus/usb 的进程：\n'
  printf '%s\n' "$USB_LS" \
    | sed -n 's#.*/proc/\([0-9]*\)/fd/.*-> */dev/bus/usb/.*#\1#p' \
    | sort -u | while read -r p; do
      [ -n "$p" ] || continue
      n="$(proc_of "$p")"
      case "$n" in
        *usbd*|*vold*|*init*|*zygote*) tag="（系统 USB 守护，正常）" ;;
        *audioserver*)                 tag="（音频栈持有 -> 本模块在链路上）" ;;
        *)                             tag="（第三方进程 -> 很可能是 App 自带 USB 驱动）" ;;
      esac
      printf '    pid %-7s %s %s\n' "$p" "$n" "$tag"
    done
fi

printf '\n  判定规则：\n'
printf '    · 第 5 段 owner 是 audioserver、且有 rate -> 走 Android 音频栈，\n'
printf '      本模块的上限【对它有效】。\n'
printf '    · 第 5 段全程 closed，但第 6 段有第三方 App 占着 /dev/bus/usb ->\n'
printf '      该 App 用自带 USB 驱动直连 DAC。此时【本模块与它无关】。\n'

# ==================================================================== 结论
sec 7 "结论（速览 + 排查明细）"

if [ -z "${MODDIR:-}" ]; then
  MODDIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
fi
mod_ver="$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1)"
if [ -z "$mod_ver" ] && [ -n "$POLICY_FILES" ]; then
  mod_ver="$(grep -h -o "$MARKER v[0-9.]*" $POLICY_FILES 2>/dev/null | head -n1 | sed "s/^$MARKER //")"
fi
if [ "$APPLIED" = yes ]; then
  MOUNT_LINE="✅ 已挂载 $MOUNTED_N 个策略文件（${mod_ver:-?} · 混音 ${CONFIG_MIX:-?} / 直通上限 ${CONFIG_MAX:-?} / 位深 ${CONFIG_BITS:-?}bit / 扬声器 ${CONFIG_SPK:-auto} / 扬声器位深 ${CONFIG_SPKBITS:-16}bit）"
elif [ -n "$POLICY_FILES" ]; then
  MOUNT_LINE="❌ 未挂载 —— 先点「应用并生效」或重启，其余判断不成立"
else
  MOUNT_LINE="❌ 本机没找到 XML 音频策略文件（Android 7 或更早），模块不适用"
fi
if [ -n "$ACT_UID" ]; then
  CLIENT_LINE="${ACT_NAME:-uid:$ACT_UID} 申请 ${ACT_FMT:-?} @ ${ACT_RATE:-?} Hz"
else
  CLIENT_LINE="当前没有 App 在播放（或曲目处于暂停）—— 播放中重跑本校验"
fi
if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
  OUTPUT_LINE="播放器自带 USB 驱动独占中（usbfs ×${USBFS_N}）—— DAC 直连，规格以 DAC 屏为准"
  VERDICT_LINE="ℹ️ 「独占 USB 输出」生效形态：音乐由 App 自带驱动直连 DAC（bit-perfect），本模块不参与也不限制"
elif [ -n "$OUT_FMT" ]; then
  OUTPUT_LINE="${OUT_CHAN:-USB 输出} → ${OUT_BITS:-?} @ ${OUT_RATE:-?} Hz 送往小尾巴"
  if [ -n "$ACT_RATE" ] && [ -n "$OUT_RATE" ] && [ "$ACT_RATE" -gt "$OUT_RATE" ] 2>/dev/null; then
    VERDICT_LINE="✅ 模块生效：App 的 ${ACT_RATE} Hz 高解析请求被接受，按 ${OUT_BITS:-?}/${OUT_RATE} Hz 输出；降档是 DAC 硬件上限（换更高上限的解码器可到 ${ACT_RATE}）"
  elif [ -n "$ACT_RATE" ] && [ -n "$OUT_RATE" ] && [ "$ACT_RATE" = "$OUT_RATE" ] 2>/dev/null; then
    VERDICT_LINE="✅ 比特完美：App 请求率与实际输出一致（${OUT_BITS:-?} @ ${OUT_RATE} Hz），无降档也无上采样"
  elif [ -n "$ACT_RATE" ] && [ -n "$OUT_RATE" ] && [ "$ACT_RATE" -lt "$OUT_RATE" ] 2>/dev/null; then
    VERDICT_LINE="✅ 输出通道在跑：${OUT_CHAN:-USB} ${OUT_BITS:-?} @ ${OUT_RATE:-?} Hz。请求 ${ACT_RATE} Hz < 输出 ${OUT_RATE} Hz = 无损上采样（不丢内容，但不是比特完美）。② 的请求率是【当前这首曲子】的采样率 —— 换歌就会变（HiRes 档位下 48k/96k/192k 都存在）。想让这一档比特完美：hifi set mixer ${ACT_RATE} 后 apply"
  else
    VERDICT_LINE="✅ 输出通道在跑：${OUT_CHAN:-USB} ${OUT_BITS:-?} @ ${OUT_RATE:-?} Hz（明细见排查段）"
  fi
elif [ "${NOTE_RUN:-no}" = yes ]; then
  OUTPUT_LINE="有 PCM 流在跑（明细见排查段第 5 条）"
  VERDICT_LINE="✅ 有音频流，规格见第 5 段明细"
elif [ "${PHONE_ACTIVE_N:-0}" -gt 0 ] || [ "${MEDIA_PLAYING_N:-0}" -gt 0 ] 2>/dev/null; then
  # No USB output, but the loudspeaker / earpiece / wired headset is carrying
  # audio.  This is a NORMAL state when no DAC is connected -- do NOT warn.
  # The module is "idling on the speaker side" and the user just doesn't have
  # a dongle plugged in.  Before v1.9 the [7] segment reported a misleading
  # "no audio in playback" warning in this case.
  spk_brief=""
  [ "${SPK_ACTIVE_N:-0}" -gt 0 ] && spk_brief="$spk_brief 扬声器(${SPK_ACTIVE_N})"
  [ "${EARPIECE_ACTIVE_N:-0}" -gt 0 ] && spk_brief="$spk_brief 听筒(${EARPIECE_ACTIVE_N})"
  [ "${WIRED_ACTIVE_N:-0}" -gt 0 ] && spk_brief="$spk_brief 有线耳机(${WIRED_ACTIVE_N})"
  if [ -z "$spk_brief" ]; then
    # routed to a built-in device that the buckets don't track (BT? BT_A2DP?)
    spk_brief="内置输出"
  fi
  OUTPUT_LINE="App 在 ${spk_brief} 上播放（未连接 USB DAC）"
  VERDICT_LINE="ℹ️ 小尾巴未连接：模块在小尾巴侧处于空载，但手机 ${spk_brief} 播放正常（媒体 started 流 ${MEDIA_PLAYING_N} 条）。插上小尾巴后 USB 链路判定立刻生效 —— 详见 5b"
else
  OUTPUT_LINE="此刻没有任何音频在播"
  VERDICT_LINE="ℹ️ 系统无音频播放：手机扬声器、听筒、有线耳机、USB DAC 都空。插上小尾巴/播一首歌后再点「开始校验」"
fi

printf '%s\n' "==================== 速览 ===================="
printf '%s\n' "① 模块挂载   : $MOUNT_LINE"
printf '%s\n' "② 音频客户端 : $CLIENT_LINE"
printf '%s\n' "③ 实际输出   : $OUTPUT_LINE"
printf '%s\n' "④ 判定       : $VERDICT_LINE"
printf '%s\n' "⑤ 扬声器档位 : ${SPK_VERDICT:-未校验（扬声器端口不存在或模块未挂载）}"
printf '%s\n' "⑥ DSP 位宽强制 : ${CONFIG_DSPBITS:-未设置}（期望 ${CONFIG_SPKDSP:-16}）"
printf '%s\n' "=============================================="
printf '%s\n' ""
printf '%s\n' "---- 排查明细（遇到问题把下面整段附在 issue 里）----"

if [ "$APPLIED" = yes ]; then
  printf '配置层 : 补丁已挂载（%s 个文件）\n' "$MOUNTED_N"
else
  printf '配置层 : 补丁【未】挂载 —— 先应用或重启，其余判断都不成立\n'
fi
printf '端口   : USB[%s] WIRED[%s] DIRECT[%s] MIX[%s] SPK[%s]\n' \
       "${USB_PORTS:-无}" "${WIRED_PORTS:-无}" "${DIR_PORTS:-无}" "${MIX_PORTS:-无}" "${SPK_PORTS:-无}"

# ⑤ 详细展开: 列出扬声器端口在补丁里的 profile, 让上面的 ⑤ 一行可对照
if [ "$SPK_PORT_SCAN" = "yes" ] && [ -n "$SPK_INFO" ]; then
  printf '扬声器端口（读取自挂载中的策略文件）:\n'
  printf '%s\n' "$SPK_INFO" | awk -F'|' '
    $2 == "MULTI" { printf "  · %s: (多率保留, 模块未触碰 — 通常是 ROM 自留接口)\n", $1; next }
    $2 != "" { printf "  · %s: 钉死率=%s Hz  /  INT_24_BIT=%s  /  INT_32_BIT=%s\n", $1, $2, ($3==1?"yes":"no"), ($4==1?"yes":"no") }
  '
  printf '扬声器档位校验 : 期望采样率=%s 位深上限=%sbit\n' \
    "${CONFIG_SPK:-auto}" "${CONFIG_SPKBITS:-16}"
fi
case "${D_VERDICT:-}" in
  D1) printf '链路层 : D1 —— 本机内核没导出 pcm 目录，/proc 观察通道不可用；以 5b/5c 为准\n' ;;
  D2) printf '链路层 : D2 —— ALSA 上没有流：检测时暂停了，或播放器自带驱动独占（4b/5c）\n' ;;
  D3) printf '链路层 : D3 —— 有 PCM 流在跑，看第 5 段每条 stream 的 rate/format 与 owner\n' ;;
  *)  printf '链路层 : 未判定\n' ;;
esac
if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
  printf 'USB 侧 : 小尾巴被 usbfs 接管 → 播放器自带 USB 驱动独占中\n'
  printf '         音乐 bit-perfect 直连 DAC，本模块与它无关；dumpsys 的活动输出是幽灵路由，别看它\n'
elif [ "${USB_ACTIVE_N:-0}" -gt 0 ] 2>/dev/null; then
  if [ "${USB_DIRECT:-no}" = yes ]; then
    printf 'USB 侧 : 有活动输出走【直通 %s】→ 模块在链路上（5b 原文即证据）\n' "${DIR_PORTS:-direct}"
  elif [ "${USB_HIFI:-no}" = yes ]; then
    printf 'USB 侧 : 有活动输出走【hifi 专用输出】→ 按 DAC 动态能力协商（见 5c 说明）\n'
  elif [ "${USB_MIXED:-no}" = yes ]; then
    printf 'USB 侧 : 有活动输出走【混音路径】→ 位深由 App 的请求决定（见 5c 说明）\n'
  else
    printf 'USB 侧 : 有活动输出到 USB，端口名未识别（见 5b 原文）\n'
  fi
elif [ "${NOTE_RUN:-no}" = yes ]; then
  printf 'USB 侧 : 第 5 段有流但 dumpsys 无活动 USB 输出 —— 以第 5 段为准\n'
elif [ "${PHONE_ACTIVE_N:-0}" -gt 0 ] || [ "${MEDIA_PLAYING_N:-0}" -gt 0 ] 2>/dev/null; then
  # No DAC connected, but the phone's own speaker / earpiece / wired is
  # carrying audio.  v1.9's [7] segment now distinguishes this from "system
  # silent": the module is correctly IDLE on the USB side and the user is
  # listening through the phone -- no warning needed.
  printf 'USB 侧 : 小尾巴未连接 —— 5b 段已扫到本机扬声器/听筒/有线耳机上有 %s 条活跃输出（speaker %s / earpiece %s / wired %s / 媒体 started 流 %s）\n' \
    "$PHONE_ACTIVE_N" "$SPK_ACTIVE_N" "$EARPIECE_ACTIVE_N" "$WIRED_ACTIVE_N" "$MEDIA_PLAYING_N"
else
  printf 'USB 侧 : 系统无音频播放（扬声器、听筒、有线耳机、 USB DAC 都空）\n'
fi
if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
  printf '归属   : 播放器自带 USB 驱动独占（usbfs×%s）——「独占 USB 输出」开启形态，模块在链路外\n' "${USBFS_N}"
elif [ -n "${ACT_NAME:-}" ] && [ -n "${OUT_FMT:-}" ]; then
  printf '归属   : %s 经 %s 通道输出 %s @ %s Hz —— 链路归属明确\n' "${ACT_NAME}" "${OUT_CHAN:-USB}" "${OUT_BITS:-?}" "${OUT_RATE:-?}"
elif [ "${USB_ACTIVE_N:-0}" -gt 0 ] 2>/dev/null; then
  printf '归属   : 有活动 USB 输出，客户端未识别（明细见 5b 客户端段）\n'
elif [ "${NOTE_MODE:-}" = android ]; then
  printf '归属   : Android 音频栈（audioserver）-> 本模块在链路上\n'
elif [ "${NOTE_MODE:-}" = app ]; then
  printf '归属   : 疑似 App 自带 USB 驱动 -> 本模块不参与\n'
elif [ "${NOTE_RUN:-no}" = yes ]; then
  printf '归属   : 有 PCM 流在跑，明细见第 5 段\n'
elif [ "${PHONE_ACTIVE_N:-0}" -gt 0 ] || [ "${MEDIA_PLAYING_N:-0}" -gt 0 ] 2>/dev/null; then
  printf '归属   : 手机扬声器/听筒/有线耳机在播（媒体 started 流 %s 条） —— 模块在 USB 侧处于空载（无小尾巴可介入），属正常形态\n' "$MEDIA_PLAYING_N"
else
  printf '归属   : 系统无音频播放 —— 播一首歌或插上小尾巴后再跑本校验\n'
fi
printf '\n下一步 : 播放中重跑本命令，看速览 ④ ——\n'
printf '         不开独占时出现 ✅ 模块生效 / ✓ 直通 / ✓ HiFi 通道 = 模块在链路上正常干预；\n'
printf '         出现 ℹ️ usbfs 接管 = 独占已开（App 直连 DAC，模块在链路外，属正常形态）；\n'
printf '         没插 DAC 时出现 ℹ️ 小尾巴未连接 = 手机扬声器/听筒在播（属正常）；\n'
printf '         异常时把「排查明细」整段发回来可继续定位。\n'
hr
fi   # want_core  ->  sections [1]..[7]

# ==============================================================================
# 8. 机型适配信息
#
# 换机型 / 刷入无效时，这一段就是"病历"。它只做检测、不改任何东西，
# 目的是回答三个问题：
#   ① 这台机器到底有哪些策略文件，模块为什么补了它 / 跳过了它
#   ② 策略基线是什么（模块挂载的东西是从哪份原厂件生成的）
#   ③ 音频输出在系统里的真实路径（逻辑端口所属文件 + 内核设备节点 + 声卡号）
# ==============================================================================
if want_adapt; then
sec 8 "机型适配信息（换机型 / 无效时请把本段整段贴给维护者）"

printf '设备       : %s (%s)\n' "$(getprop ro.product.device 2>/dev/null)" "$(getprop ro.product.model 2>/dev/null)"
printf '平台       : %s %s\n' "$(getprop ro.soc.model 2>/dev/null)" "$(getprop ro.board.platform 2>/dev/null)"
printf '系统       : SDK %s  %s\n' "$(getprop ro.build.version.sdk 2>/dev/null)" "$(getprop ro.build.display.id 2>/dev/null)"
printf 'SELinux    : %s\n' "$(getenforce 2>/dev/null || echo unknown)"
printf 'audioserver: %s\n' "$(getprop init.svc.audioserver 2>/dev/null)"
printf '模块       : %s v%s\n' "$MOD_ID" "$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"

printf '\n--- ① 框架自己说它在读哪个配置 ---\n'
cs="$(dumpsys media.audio_policy 2>/dev/null | sed -n 's/.*Config source: *//p' | head -n1 | tr -d '\r')"
if [ -n "$cs" ]; then
  printf '  Config source : %s\n' "$cs"
  case "$cs" in
    /*) printf '  → 是一个文件路径，模块会优先补它\n' ;;
    *)  printf '  → 不是文件路径（例如 AIDL HAL = 策略由 HAL 自带），此时只能靠 HAL 库那一层\n' ;;
  esac
else
  printf '  (读不到：audioserver 未运行或 dumpsys 被拒)\n'
fi

printf '\n--- ② 模块上次扫描的结论（策略文件 + 每个为什么补 / 为什么跳过）---\n'
if [ -r "$STATE/report.txt" ]; then
  sed 's/^/  /' "$STATE/report.txt"
else
  printf '  (没有扫描报告：模块可能从未成功扫描，或 state 目录被清)\n'
fi

printf '\n--- ③ 本机实时存在的策略/配置文件（不依赖模块的判断）---\n'
_found=0
for r in /odm /vendor /system/vendor /product /system/etc /system/product/etc; do
  [ -d "$PROOT$r" ] || continue
  find "$PROOT$r" -maxdepth 6 -type f \( -name '*audio_policy_configuration*.xml' -o -name 'audio_module_config_*.xml' \) 2>/dev/null \
    | while IFS= read -r f; do
        printf '  %-64s %s bytes\n' "$f" "$(wc -c <"$f" 2>/dev/null | tr -d ' ')"
      done
done
printf '  --- 各文件用的方言（决定改写规则）---\n'
for r in /odm /vendor /system/vendor /system/etc; do
  [ -d "$PROOT$r" ] || continue
  find "$PROOT$r" -maxdepth 6 -type f -name '*audio_policy_configuration*.xml' 2>/dev/null \
    | while IFS= read -r f; do
        q="$(grep -c 'pcmType="' "$f" 2>/dev/null)"; a="$(grep -c 'format="AUDIO_FORMAT_' "$f" 2>/dev/null)"
        case "$q:$a" in
          0:0) d="?" ;;
          *)   if [ "${q:-0}" -gt "${a:-0}" ] 2>/dev/null; then d=qti; else d=aosp; fi ;;
        esac
        printf '  %-6s %s\n' "$d" "$f"
      done
done

printf '\n--- ④ 音频输出在系统里的真实路径 ---\n'
printf '  逻辑层（策略里 USB / WIRED / DIRECT 输出口，以及它们所属的文件）:\n'
for f in $POLICY_FILES; do
  real="${POLICY_ROOT:-}${f}"
  [ -r "$real" ] || continue
  hits="$(port_scan "$real" | grep -E '^(USB|WIRED|DIR)\|' | sed 's/|/ /' | tr '\n' ';')"
  [ -n "$hits" ] && printf '    %s\n        %s\n' "$f" "$hits"
done
[ -n "$POLICY_FILES" ] || printf '    (没有生效中的策略文件)\n'
printf '  物理层（内核导出给 Android 的声卡与 PCM 节点）:\n'
if [ -d "$CARD_ROOT" ]; then
  [ -r "$CARD_ROOT/cards" ] && sed 's/^/    /' "$CARD_ROOT/cards"
  for pcm in "$CARD_ROOT"/card[0-9]*/pcm*c "$CARD_ROOT"/card[0-9]*/pcm*p; do
    [ -e "$pcm" ] && printf '    %s\n' "${pcm#$CARD_ROOT/}"
  done
  for st in "$CARD_ROOT"/card[0-9]*/stream0; do
    [ -e "$st" ] && printf '    %s\n' "${st#$CARD_ROOT/}"
  done
else
  printf '    %s 不存在（内核未导出，无法读取）\n' "$CARD_ROOT"
fi
printf '  框架侧（dumpsys 里 USB 设备绑定的声卡号）:\n'
dumpsys media.audio_policy 2>/dev/null | grep -o 'card=[0-9]*;device=[0-9]*' | sort -u | sed 's/^/    @:/' | head -8
dumpsys media.audio_policy 2>/dev/null | grep -o '"USB Device Out"\|"USB Headset Out"\|"Wired Headset Out"\|"Wired Headphones Out"' | sort -u | sed 's/^/    端口: /'

printf '\n--- ⑤ USB HAL 库（第二层的目标）---\n'
_n=0
for d in /odm/lib64 /odm/lib /vendor/lib64 /vendor/lib /system/vendor/lib64 /system/vendor/lib /system/lib64 /system/lib; do
  for l in libalsautils.so libalsautilsv2.so; do
    [ -e "$PROOT$d/$l" ] || continue
    _n=$((_n + 1))
    ls -l "$PROOT$d/$l" 2>/dev/null | sed 's/^/  /'
  done
done
[ "$_n" = 0 ] && printf '  （本机没有 libalsautils{,v2}.so —— 第二层无目标，模块会跳过，属正常结果）\n'

printf '\n--- ⑥ 策略基线（模块挂载的内容就是由这些原厂件生成的）---\n'
if [ -d "$STATE/stock" ] && [ -n "$(ls -A "$STATE/stock" 2>/dev/null)" ]; then
  for a in "$STATE"/stock/*; do
    [ -f "$a" ] || continue
    printf '  %-52s %8s bytes\n' "$(basename "$a")" "$(wc -c <"$a" 2>/dev/null | tr -d ' ')"
  done
else
  printf '  (没有归档：模块尚未成功补丁过任何文件)\n'
fi

printf '\n--- 反馈时请附上 ---\n'
printf '  1) 本段 [8] 整段（含 ①②③④⑤⑥）\n'
printf '  2) 本段 [7] 的"排查明细"整段\n'
printf '  3) 一句话：型号 / 系统版本 / 小尾巴型号 / 现象（无声、卡在 96k、还是完全没反应）\n'
printf '  想一次性导出成文件的话：在管理器终端执行\n'
printf '     sh /data/adb/modules/%s/bin/hifi report\n' "$MOD_ID"
printf '  它会写到 /data/local/tmp/hifi_src_bypass_report.txt，无需 root 即可 adb pull 取回。\n'
hr

# --- 8·A SmartPA 检测（扬声器档位的物理天花板） -----------------------------
#
# WSA881x 类 SmartPA 的内核驱动把 DAI 硬锁在 48000 / S16 / mono
# （上游 wsa881x.c：rates = SNDRV_PCM_RATE_48000, rate_max = 48000），
# 这类机型上 SPK 采样率档位超过 48k 物理无效 —— 调了也只是白耗电。
# WSA883x 及更新型号数字接口支持到 384k，但 ADSP 侧扬声器保护/EQ 的
# 处理率通常仍 ≤48k，更高档位没有可闻收益。
# 探测手段按优先级排列，全部失败时明确说"未识别"，绝不空段、绝不报错。
printf '\n--- SmartPA 检测（扬声器档位的物理天花板）---\n'
_SP_MODEL=""
_SP_EVID=""

# 信号 1：内核日志（需 root；dmesg 受限则降级 /proc/kmsg，再不行就跳过。
# kmsg 是阻塞读，必须套 timeout，否则非 root/静默内核下 probe 会挂死）
_dm="$(dmesg 2>/dev/null | grep -ioE 'wsa88[0-9x]+|cs35l[0-9]+|tfa9[0-9]+|smartpa' | sort -u | tr '\n' ' ')"
if [ -z "$_dm" ] && [ ! -r /proc/kmsg ]; then
  :   # dmesg 没给出线索，且 kmsg 也不可读 —— 静默走下一个信号
elif [ -z "$_dm" ] && command -v timeout >/dev/null 2>&1; then
  _dm="$(timeout 2 dd if=/proc/kmsg bs=4096 count=8 2>/dev/null | grep -ioE 'wsa88[0-9x]+|cs35l[0-9]+|tfa9[0-9]+|smartpa' | sort -u | tr '\n' ' ')"
fi
case "$(printf '%s' "$_dm" | tr 'A-Z' 'a-z')" in
  *wsa881*) _SP_MODEL=WSA881x; _SP_EVID="kernel log: $_dm" ;;
  *wsa883*) _SP_MODEL=WSA883x; _SP_EVID="kernel log: $_dm" ;;
  *wsa884*) _SP_MODEL=WSA884x; _SP_EVID="kernel log: $_dm" ;;
  *cs35l4*) _SP_MODEL=CS35L4x; _SP_EVID="kernel log: $_dm" ;;
  *tfa9*)   _SP_MODEL=TFA98xx; _SP_EVID="kernel log: $_dm" ;;
esac

# 信号 2：platform 设备节点（wsa* 出现在 /sys/bus/platform/devices）
if [ -z "$_SP_MODEL" ]; then
  for _d in /sys/bus/platform/devices/*wsa* /sys/bus/soundwire/devices/*wsa*; do
    [ -e "$_d" ] || continue
    case "$(basename "$_d")" in
      *wsa881*) _SP_MODEL=WSA881x ;;
      *wsa883*) _SP_MODEL=WSA883x ;;
      *wsa884*) _SP_MODEL=WSA884x ;;
      *wsa*)    [ -z "$_SP_MODEL" ] && _SP_MODEL=WSA ;;
    esac
    [ -n "$_SP_MODEL" ] && _SP_EVID="sysfs: $(basename "$_d")"
    break
  done
fi

# 信号 3：厂商库指纹（libwpa*.so = WSA 家族伴随库；spkr_prot 也指向 SmartPA 链）
if [ -z "$_SP_MODEL" ]; then
  for _l in "$PROOT"/vendor/lib64/libwpa*.so "$PROOT"/odm/lib64/libwpa*.so \
            "$PROOT"/vendor/lib64/libspkr_prot.so "$PROOT"/odm/lib64/libspkr_prot.so; do
    [ -e "$_l" ] || continue
    case "$(basename "$_l")" in
      *881*) _SP_MODEL=WSA881x ;;
      *883*) _SP_MODEL=WSA883x ;;
      *)     [ -z "$_SP_MODEL" ] && _SP_MODEL=WSA ;;
    esac
    [ -n "$_SP_MODEL" ] && _SP_EVID="vendor lib: $(basename "$_l")"
    break
  done
fi

case "$_SP_MODEL" in
  WSA881x) printf 'SmartPA: WSA881x（WSA881x 内核驱动 DAI 硬锁 48kHz/S16——SPK 采样率档位超过 48k 在此机型物理无效）\n' ;;
  WSA883x|WSA884x) printf 'SmartPA: %s（数字层支持高率，但 ADSP 扬声器处理率通常 ≤48k，>48k 档位无可闻收益，功耗增加）\n' "$_SP_MODEL" ;;
  CS35L4x|TFA98xx) printf 'SmartPA: %s（第三方 SmartPA：片上 DSP 自带保护/EQ，>48k 档位收益以实测为准）\n' "$_SP_MODEL" ;;
  WSA)     printf 'SmartPA: WSA 系列（具体型号未定，SPK 档位效果以实测为准；证据：%s）\n' "$_SP_EVID" ;;
  *)       printf 'SmartPA: 未识别（型号未知，SPK 档位效果以实测为准）\n' ;;
esac
[ -n "$_SP_EVID" ] && printf '  证据: %s\n' "$_SP_EVID"
[ -z "$_SP_EVID" ] && printf '  （无内核日志/sysfs/厂商库线索；dmesg 需要 root，非 root 下信息更少）\n'
unset _SP_MODEL _SP_EVID _dm _d _l

# --- 8·B USB offload 检测（本模块 USB 解锁会不会被 ADSP 旁路） ---------------
#
# 高通 USB offload（ADSP 直驱 USB，内核 qc_audio_offload / snd-usb-audio-qcom）
# 路径上采样率由 ADSP 决策，libalsautils 的 52 字节表与策略 XML 都不在链路上
# —— 模块的 USB 解锁会静默失效。这里把这件事在出问题之前就告诉用户。
printf '\n--- USB offload 检测（USB 解锁是否会被 ADSP 旁路）---\n'
_UO_N=0
_UO_WHY=""
_gp="$(getprop 2>/dev/null | grep -iE 'usboffload|usb_offload' | tr -d '\r')"
[ -n "$_gp" ] && { _UO_N=$((_UO_N + 1)); _UO_WHY="$_UO_WHY
  getprop: $_gp"; }
for _p in ro.vendor.audio.usboffload.psd.enabled \
          ro.vendor.audio.usboffload.enabled \
          ro.vendor.audio.usb.offload.region \
          vendor.audio.usb.offload \
          persist.vendor.audio.usb.offload; do
  _v="$(getprop "$_p" 2>/dev/null | tr -d '\r')"
  [ -n "$_v" ] || continue
  _UO_N=$((_UO_N + 1)); _UO_WHY="$_UO_WHY
  getprop $_p = $_v"
done
_lm="$(cat /proc/modules 2>/dev/null | grep -iE 'qc_audio_offload|usb_audio_qmi|snd_usb_audio_qmi|usb_f_audio' | tr -d '\r')"
if [ -z "$_lm" ] && [ -d "$PROOT/vendor/lib/modules" ]; then
  _lm="$(ls "$PROOT"/vendor/lib/modules "$PROOT"/odm/lib/modules 2>/dev/null | grep -iE 'qc_audio_offload|usb_audio_qmi|snd_usb_audio_qmi' | head -n 4)"
fi
[ -n "$_lm" ] && { _UO_N=$((_UO_N + 1)); _UO_WHY="$_UO_WHY
  内核模块: $(printf '%s' "$_lm" | head -n 3)"; }
if [ -r "$CARD_ROOT/cards" ]; then
  _oc="$(grep -iE 'offload|fe\.' "$CARD_ROOT/cards" 2>/dev/null | tr -d '\r' | head -n 4)"
  [ -n "$_oc" ] && { _UO_N=$((_UO_N + 1)); _UO_WHY="$_UO_WHY
  声卡表: $_oc"; }
fi

if [ "$_UO_N" -gt 0 ]; then
  printf '⚠ 检测到高通 USB offload 路径：本模块的 USB HAL 表解锁可能不参与采样率决策\n'
  printf '  （ADSP 直驱 USB）。若 USB DAC 仍卡 96k，这是原因，不是模块失效。\n'
else
  printf '未检测到 USB offload：本模块 USB 解锁路径正常。\n'
fi
[ -n "$_UO_WHY" ] && printf '  证据:%s\n' "$_UO_WHY"
unset _UO_N _UO_WHY _gp _p _v _lm _oc

# ==============================================================================
# 9. 厂商 DSP 状态
#
# 回答"能不能做出类杜比音效"这件事的前半段：本机链路里到底有没有厂商 DSP
# 在动声音。DSP 算法（杜比 / Dirac / DTS）受商业 license + 系统签名锁死，
# 模块做不了也不做 —— 但可以检测它是否存在并提示在哪里手动关掉：
# 链路越干净，本模块"零重采样 + 位深补齐"的收益就越直接。
# 只做检测 + 提示，不碰任何厂商组件。
# ==============================================================================
sec 9 "厂商 DSP 状态（类杜比问题的前半段：先让链路纯净）"

VDSP_N=0
VDSP_NAMES=""
VDSP_RAW=""

# --- ① 系统特性声明（pm list features）---
_fts="$(pm list features 2>/dev/null | grep -iE 'dolby|dirac|dts|audiofx|soundeffect' | tr -d '\r')"
if [ -n "$_fts" ]; then
  printf '\n--- ① 系统特性声明（pm list features）---\n'
  printf '%s\n' "$_fts" | sed 's/^/  /'
  VDSP_N=$((VDSP_N + 1)); VDSP_NAMES="$VDSP_NAMES features"
  VDSP_RAW="$VDSP_RAW
$_fts"
fi

# --- ② 装了的 DSP 相关包（pm list packages）---
_pkgs="$(pm list packages 2>/dev/null | grep -iE 'dolby|dirac|dts|audiofx|miui\.audio|oplus|audioeffect|soundeffect' | tr -d '\r')"
if [ -n "$_pkgs" ]; then
  printf '\n--- ② DSP 相关包（pm list packages，%s 个）---\n' "$(printf '%s\n' "$_pkgs" | grep -c .)"
  printf '%s\n' "$_pkgs" | sed 's/^/  /'
  VDSP_N=$((VDSP_N + 1)); VDSP_NAMES="$VDSP_NAMES packages"
  VDSP_RAW="$VDSP_RAW
$_pkgs"
fi

# --- ③ Spatializer（系统级空间音效）---
_spat="$(dumpsys media.audio_policy 2>/dev/null | grep -iE 'spatializer|dolby|dirac' | tr -d '\r' | head -n 8)"
if [ -n "$_spat" ]; then
  printf '\n--- ③ Spatializer / 空间音效（dumpsys media.audio_policy）---\n'
  printf '%s\n' "$_spat" | sed 's/^/  /'
  VDSP_N=$((VDSP_N + 1)); VDSP_NAMES="$VDSP_NAMES spatializer"
  VDSP_RAW="$VDSP_RAW
$_spat"
fi

# --- ④ 策略 XML 里声明的 effect 库 ---
for f in /vendor/etc/audio_policy_configuration.xml \
         /odm/etc/audio/*.xml /vendor/etc/audio/*.xml; do
  [ -r "$f" ] || continue
  h="$(stripc "$f" | grep -iE '<effectLibraries>|<effects[ >]' | head -n 4)"
  [ -n "$h" ] || continue
  printf '\n--- ④ 策略 XML 声明的效果库 ---\n'
  printf '  %s:\n' "$f"
  printf '%s\n' "$h" | sed 's/^/    /'
  VDSP_N=$((VDSP_N + 1)); VDSP_NAMES="$VDSP_NAMES xml-effects"
  VDSP_RAW="$VDSP_RAW
$h"
done

# 归并命中的厂商名（跨层去重），得到 "N 个厂商 DSP（Dolby、Dirac）" 这种结论
VDSP_HITS="$(printf '%s\n' "$VDSP_RAW" | grep -ioE 'dolby|dirac|dts|audiofx|mi ?sound|magic ?sound|oplus ?audio|soundeffect' | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ')"
VDSP_HITS="$(printf '%s' "$VDSP_HITS" | sed 's/ *$//')"
[ -z "$VDSP_HITS" ] && VDSP_HITS="$(printf '%s' "$VDSP_NAMES" | sed 's/^ //')"
VDSP_C=0
for _t in $VDSP_HITS; do VDSP_C=$((VDSP_C + 1)); done
VDSP_LIST="$(printf '%s' "$VDSP_HITS" | sed 's/mi sound/Mi Sound/g; s/magic sound/Magic Sound/g; s/oplus audio/Oplus Audio/g; s/\baudiofx\b/AudioFX/g; s/\bdts\b/DTS/g; s/\bdolby\b/Dolby/g; s/\bdirac\b/Dirac/g; s/\bsoundeffect\b/SoundEffect/g; s/ /、/g')"

# --- ⑤ 结论 + 关闭引导 ---
printf '\n--- ⑤ 结论 ---\n'
if [ "$VDSP_N" -gt 0 ]; then
  printf '  检测到 %s 个厂商 DSP（%s）—— 信号来自：%s。\n' "$VDSP_C" "$VDSP_LIST" \
    "$(printf '%s' "$VDSP_NAMES" | sed 's/^ //; s/ /、/g')"
  printf '  这些 DSP 会在扬声器链路上再加工（空间音频 / 响度补偿 / EQ），\n'
  printf '  与本模块的「零重采样 + 位深补齐」叠加后听感未必更好。\n'
  printf '  建议手动关闭（模块不代劳，这是系统设置里的事）：\n'
  printf '    设置 → 声音与振动 → 音效 / 杜比全景声 / Dirac → 关闭\n'
  printf '    或（仅 Spatializer）：adb shell settings put global spatializer_mode 0\n'
else
  printf '  未检测到厂商 DSP（纯净）—— 链路里没有额外的加工层。\n'
fi
printf '\n  说明：以上仅检测，本模块不会替你关闭任何厂商组件；\n'
printf '  就算全部关掉，「类杜比」的算法本身（虚拟环绕 / 响度模型）也是\n'
printf '  商业 license + 系统签名锁死的，开源模块做不了，本模块做的是\n'
printf '  链路纯净：零重采样 + 位深补齐，让原始内容原样到达扬声器。\n'
hr
fi   # want_adapt  ->  sections [8] + [9]
exit 0
