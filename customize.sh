#!/system/bin/sh
# ==============================================================================
# HiFi SRC Bypass - installer            v2.0.2
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
ui_print "  HiFi SRC Bypass  (universal)   v2.0.2"
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
if [ -z "$FOUND" ] && command -v find >/dev/null 2>&1; then
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
if [ -z "$FOUND" ] && ! command -v find >/dev/null 2>&1; then
  # this section is only a REPORT (the controller re-scans at boot), but saying
  # "no XML audio policy found" because the tool was missing would be a lie.
  ui_print "- audio policy : not enumerated (no find on this PATH)"
  ui_print "  informational only -- the controller rescans by itself: run 'hifi scan'"
fi

if [ -n "$FOUND" ]; then
  ui_print "- audio policy :"
  for f in $FOUND; do ui_print "      $f"; done
elif command -v find >/dev/null 2>&1; then
  # only a COMPLETED search may claim the ROM has no XML policy at all
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

# ------------------------------------------------------- previous generation
# A read-only probe: this only REPORTS that the old module's settings exist.
# The actual migration (which runs the controller and therefore needs the state
# dir to exist) happens far below, after the gate.
OLD_STATE=/data/adb/op13_hifi

# ==============================================================================
# CONFLICT GATE -- what gets installed and what must be refused
#
# 🔴 ORDER MATTERS: this gate runs BEFORE the state directory is created and
# BEFORE config.conf is written, and it must stay that way.  The refusal text
# below promises the user "本次安装未写入任何文件 / Nothing has been installed",
# and until this was reordered that promise was FALSE: mkdir -p "$STATE/stock"
# + the config.conf heredoc ran first, so every refused install still left a
# ghost /data/adb/hifi_src_bypass/{stock,patched,config.conf} behind.  A ghost
# config.conf is not harmless -- it is what the controller reads at boot
# (`ENABLED=1` in it makes post-fs-data mount the patch), so a refused install
# would arm the very thing that was just refused.  `run_t4_tests.py` section C
# catches it by asserting that no refused install writes config.conf.
#
# Two modules that both rewrite the audio policy / the USB HAL / the effect
# registration do not "share" anything: whichever mounts last wins, and the
# loser's assumptions are silently violated.  On the devices this module targets
# that shows up as the phone never painting the boot animation (a policy the
# vendor HAL rejects makes AudioFlinger abort with "frame size was 0" ->
# audioserver crash loop), as a system mixer path rewritten under the framework
# (volume handling stalls), or as an audio_effects XML that references a library
# which is no longer there (audio dies outright).
#
# Detecting this by MODULE ID cannot work: a list of ids is always one release
# behind (a new "Dolby" or "VIPER" repack appears every week), and two modules
# with completely different names can ship the same file.  So the rule below is
# FILE COVERAGE: a module is a conflict when it SHIPS A FILE THAT LANDS IN THE
# SAME LAYER AS OURS.  Ids are still matched as a fast path, so the message can
# name the well-known packages even when their internals are exotic.
#
# This runs BEFORE anything is written, and a hit ABORTS the installation.
# "Generally no" is the community answer to stacking audio modules (Androidacy)
# and the AML registry is literally the list of modules that rewrite
# audio_effects -- installing on top of one is not a configuration, it is a
# coin flip on whether the phone boots.
# ==============================================================================

# Test hook: prefix for the module tree, so this gate can be exercised in a
# sandbox.  It only ever MOVES the roots that are scanned -- it cannot disable
# the detection or the abort.
ROOT="${HIFI_FAKE_ROOT:-}"
ADB="$ROOT/data/adb"

# our own id, twice over: module.prop is authoritative, the staging dir name is
# the fallback (the installer knows MODPATH regardless of what module.prop says)
SELF_ID="$(sed -n 's/^id=//p' "$MODPATH/module.prop" 2>/dev/null | head -n1)"
[ -n "$SELF_ID" ] || SELF_ID="${MODPATH##*/}"
[ -n "$SELF_ID" ] || SELF_ID=hifi_src_bypass
# the previous generation of this very module: it bind-mounts the SAME policy
# files, so it is a conflict by definition, not a heuristic
LEGACY_ID=op13_hifi_src_bypass

# well-known conflicting packages: names are matched case-insensitively against
# the module DIRECTORY name and against library file names only.  Deliberately
# NOT matched against arbitrary paths -- a ROM's own media_codecs_dolby_audio.xml
# is a CODEC DECLARATION, not an audio effect, and must not be read as a conflict.
KNOWN_RE='dolby|dax|viper|v4a|auroraaudio|aurora_audio|jamesdsp|misound|aml\b|audio modification library|acdb|sony.*audio|harman|spatializer|audiowizard|xperia.*audio|nrcam|hi-res audio'

# a path -> layer, for the report.  Matching is done on the LOWER-CASED path.
layer_of() {
  _p="$1"
  case "$_p" in
    *media_codecs*.xml|*/codecs/*|*media_profiles*.xml) return 1 ;;  # codec declaration, not audio
  esac
  case "$_p" in
    *mixer_paths*.xml)                        printf 'mixer_paths (混音通路表)' ;;
    *audio_policy_configuration*.xml)         printf 'audio_policy_configuration (音频策略主文件)' ;;
    *audio_module_config_*.xml)               printf 'audio_module_config_* (HAL 模块能力声明)' ;;
    *audio_policy_volumes*.xml|*audio_policy_engine_*volumes*.xml|*volumes*.xml)
                                              printf 'volumes (音量曲线表)' ;;
    *audio_effects*.xml)                      printf 'audio_effects (音效/效果注册表)' ;;
    *audio*effects*spatializer*.xml)          printf 'audio_effects spatializer (空间音频注册)' ;;
    *audio*effects*haptic*.xml)               printf 'audio_effects haptic (触感通道注册)' ;;
    *libalsautils*.so)                        printf 'libalsautils (USB HAL 采样率表)' ;;
    *libv4a_*.so|*viper*)                     printf 'ViPER4Android 音效库' ;;
    *libhwdax*.so|*libswdax*.so|*libswdap*.so|*libdolby*.so|*dolby*) printf 'Dolby/DAX 音效库' ;;
    *libjamesdsp*.so|*jamesdsp*)              printf 'JamesDSP 音效库' ;;
    *libbassboostMz.so|*libvirtualizerMz.so|*liblivemusicMz.so|*libequalizerMz.so)
                                              printf 'MiSound 音效库' ;;
    *audio_effects*)                          printf 'audio_effects 相关文件' ;;
  esac
  return 0
}

# ==============================================================================
# TRAVERSAL WITHOUT EXTERNAL TOOLS  (finding F3)
#
# The gate used to read:
#     if command -v find >/dev/null 2>&1; then _files="$(find ... )"; else _files=""; fi
# and an EMPTY _files was indistinguishable from "walked the module, nothing in
# our layers".  Both fell through the same `if [ -n "$_hits" ]` and the install
# went on to print "no module competing for the audio policy / USB HAL /
# audio_effects layer" -- an active all-clear on a device that had never been
# scanned.  `disable` / `remove` / `skip_mount` style modules are exactly the
# ones that show up on a ROM whose init-time PATH is trimmed, so this was the
# dangerous direction: a missed conflict, never a false one.
#
# So the walk is pure shell -- glob expansion plus a depth counter.  It behaves
# IDENTICALLY with and without `find`, and it reports when it did NOT finish
# (WALK_TRUNC), which is the piece that did not exist before.  An unfinished or
# impossible scan is a hard failure below, never a silent pass.
WALK_MAXDEPTH=8      # a pathological tree must not cost minutes
WALK_LIMIT=4000      # ... and a 100k-file module must not either
walk_reset() { WALK_FILES=""; WALK_COUNT=0; WALK_TRUNC=0; WALK_BASE=""; }

walk_tree() {        # $1 = directory, $2 = depth.  Fills WALK_FILES (relative)
  _wt_dir="$1"
  _wt_d="${2:-0}"
  if [ "$_wt_d" -gt "$WALK_MAXDEPTH" ]; then WALK_TRUNC=1; return 0; fi
  # both the plain and the dot glob, so a hidden subtree is not a blind spot
  for _wt_e in "$_wt_dir"/* "$_wt_dir"/.[!.]*; do
    [ -e "$_wt_e" ] || [ -L "$_wt_e" ] || continue
    if [ -d "$_wt_e" ]; then
      walk_tree "$_wt_e" $((_wt_d + 1))
      [ "$WALK_TRUNC" = 1 ] && return 0
      continue
    fi
    WALK_COUNT=$((WALK_COUNT + 1))
    if [ "$WALK_COUNT" -gt "$WALK_LIMIT" ]; then WALK_TRUNC=1; return 0; fi
    case "$_wt_e" in
      "$WALK_BASE"/*)
        WALK_FILES="$WALK_FILES${_wt_e#"$WALK_BASE"/}
" ;;
    esac
  done
  return 0
}

# Lower-casing is what makes layer_of()'s patterns work, so it must not be the
# NEXT silent dependency: tr -> sed -> awk.  If none of the three exists the
# module is treated as unscannable (a conflict), not as clean.
LOWER_CMD=""
for _c in tr sed awk; do
  command -v "$_c" >/dev/null 2>&1 && { LOWER_CMD="$_c"; break; }
done
lower() {
  case "$LOWER_CMD" in
    tr)  printf '%s' "$1" | tr 'A-Z' 'a-z' ;;
    sed) printf '%s' "$1" | sed 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/' ;;
    awk) printf '%s' "$1" | awk '{ print tolower($0) }' ;;
    *)   printf '%s' "$1" ;;
  esac
}

CONFLICT_IDS=""
CONFLICT_N=0
SCAN_INCOMPLETE=""
DISABLED_NOTE=""
scan_root() {
  _dir="$1"
  [ -d "$_dir" ] || return 0
  for _m in "$_dir"/*; do
    [ -d "$_m" ] || continue
    _id="${_m##*/}"
    case "$_id" in
      "$SELF_ID") continue ;;
      "$LEGACY_ID")
        # the previous generation of THIS module: it bind-mounts the same policy
        # files, so there is no heuristic needed -- it is a conflict by identity.
        # (A module manager may additionally have disabled it; even then the
        # user should see it named, because re-enabling it later would conflict
        # with what is being installed right now.)
        CONFLICT_N=$((CONFLICT_N + 1))
        CONFLICT_IDS="$CONFLICT_IDS $_id"
        ui_print ""
        ui_print "  冲突模块 / conflicting module : $_id  (上一代同名模块)"
        ui_print "  冲突文件 / conflicting files  : 与本模块完全相同（同一批 audio policy / HAL 目标）"
        continue ;;
    esac
    # a disabled / being-removed module mounts NOTHING, so it cannot conflict.
    # Report it anyway -- the user should know it is sitting there.
    #
    # skip_mount is NOT in that group (finding F3b, review 2.2).  `skip_mount`
    # means "do not mount this module's tree" for the *files it does not
    # declare*, yet its overlay dirs can still be mounted from a later stage --
    # and, more importantly, the reviewer's point stands regardless: it is not
    # an inert marker like `disable`, so treating it as inert would be a
    # judgement call, and a judgement call is exactly what this gate must not
    # make.  A skip_mount module is therefore SCANNED like any other and its
    # marker is reported in the same breath, so the user sees both facts.
    _inert=0
    if [ -e "$_m/disable" ] || [ -e "$_m/remove" ]; then _inert=1; fi
    _skipmount=0
    if [ -e "$_m/skip_mount" ]; then _skipmount=1; fi
    if [ "$_inert" = 1 ]; then
      DISABLED_NOTE="$DISABLED_NOTE $_id(已禁用)"
      continue
    fi
    _hits=""
    _namelit=""
    # fast path: the module's own name names a known audio-effect package.
    # Kept AHEAD of the layer table on purpose (conservative: refuse when the
    # name alone is damning), but the hit is reported in its OWN section below
    # (finding F7): when this is the only reason, the "conflicting files"
    # section used to print a header with nothing under it, which reads like a
    # bug in the report and invites the user to dismiss the whole warning.
    if command -v grep >/dev/null 2>&1 \
       && printf '%s' "$_id" | grep -qiE "$KNOWN_RE" 2>/dev/null; then
      _namelit=1
    fi
    _idlower="$(lower "$_id")"
    # the real rule: every file the module would mount, tested against the layer
    # table above.  Pure-shell walk, depth- and count-bounded, identical with
    # or without `find` (see the TRAVERSAL note).
    walk_reset
    WALK_BASE="$_m"
    walk_tree "$_m" 0
    if [ "$WALK_TRUNC" = 1 ]; then
      SCAN_INCOMPLETE="$SCAN_INCOMPLETE $_id(截断于 $WALK_MAXDEPTH 层 / $WALK_LIMIT 文件)"
    fi
    # read the walk result line by line instead of word-splitting it: a module
    # path may legally contain a space, and `for _f in $_files` would shred it.
    # A here-document (not a pipeline) so the loop stays in THIS shell -- a
    # `... | while read` would run in a subshell and lose every assignment,
    # including the one that reports conflicts.
    while IFS= read -r _rel; do
      [ -n "$_rel" ] || continue
      _l="$(lower "$_rel")"
      _layer="$(layer_of "$_l")" || continue
      [ -n "$_layer" ] || continue
      _hits="$_hits $_rel -> $_layer
"
    done <<WALKED
$WALK_FILES
WALKED
    if [ -n "$_hits" ] || [ "$_namelit" = 1 ]; then
      CONFLICT_N=$((CONFLICT_N + 1))
      CONFLICT_IDS="$CONFLICT_IDS $_id"
      ui_print ""
      ui_print "  冲突模块 / conflicting module : $_id"
      if [ "$_skipmount" = 1 ]; then
        ui_print "  模块标记     / module marker     : skip_mount（本模块仍按文件覆盖面判定，标记不豁免）"
      fi
      if [ "$_namelit" = 1 ]; then
        ui_print "  冲突原因     / reason           : 模块名命中已知冲突音频模块"
      fi
      if [ -n "$_hits" ]; then
        ui_print "  冲突文件 / conflicting files  :"
        printf '%s' "$_hits" | while IFS= read -r _line; do
          [ -n "$_line" ] && ui_print "      $_line"
        done
      else
        ui_print "  冲突文件 / conflicting files  : （无具体文件命中，判定来自模块名）"
      fi
    fi
  done
  return 0
}

ui_print ""
if [ -d "$ADB/modules" ] || [ -d "$ADB/modules_update" ]; then
  scan_root "$ADB/modules"
  scan_root "$ADB/modules_update"
fi

# ==============================================================================
# INCOMPLETE SCAN = REFUSAL  (finding F3, the actual fix)
#
# "Cannot scan" must never map to "nothing found".  The traversal above is
# bounded (depth 8 / 4000 files) so a hostile or simply enormous module cannot
# hang the installer -- but a bounded walk that stopped early is NOT evidence
# of a clean device, so it fails closed exactly like a conflict does.
# Two tools the judgement itself depends on.  Neither is optional:
#   * tr/sed/awk -- layer_of() patterns are lower-cased, so with none of them
#     every path classifies as "not our layer" (a silent all-clear);
#   * grep       -- the module-name fast path cannot run at all, so a
#     name-only conflict (a repack whose files sit in an unexpected place)
#     would be missed.
# Both absences are reported as an INCOMPLETE scan, i.e. the same refusal.
if [ -z "$LOWER_CMD" ]; then
  SCAN_INCOMPLETE="$SCAN_INCOMPLETE (no tr/sed/awk: cannot classify a single path)"
fi
if ! command -v grep >/dev/null 2>&1; then
  SCAN_INCOMPLETE="$SCAN_INCOMPLETE (no grep: the module-name fast path cannot run)"
fi

if [ -n "$SCAN_INCOMPLETE" ]; then
  ui_print ""
  ui_print "################################################################"
  ui_print "#                                                              #"
  ui_print "#     !!!  冲突检查不完整 / CONFLICT CHECK INCOMPLETE  !!!     #"
  ui_print "#                                                              #"
  ui_print "################################################################"
  ui_print ""
  ui_print "  无法完成的扫描 :$SCAN_INCOMPLETE"
  ui_print ""
  ui_print "  【为什么中止 / why this refuses instead of continuing】"
  ui_print "  这个闸门只能在【完整扫描】之后才有资格说"没有冲突"。上面这些模块没有"
  ui_print "  被完整扫描（层数/文件数超出上限，或缺少 tr/sed/awk 导致路径无法归类），"
  ui_print "  所以"没发现问题"只是"没看完"，不是"没问题"。"
  ui_print "  把"没看完"当成"没问题"放行，正是本模块最不能犯的错误：两个模块同时"
  ui_print "  改写同一音频层时，代价是开机卡屏/音量卡死，而不是一条日志。"
  ui_print ""
  ui_print "  【怎么做 / what to do】"
  ui_print "   1) 先卸载/禁用那些模块，再重新刷入本模块；"
  ui_print "   2) 或在一个工具链完整的 shell（含 tr、sed 或 awk）里重跑安装器。"
  ui_print ""
  ui_print "  本次安装未写入任何文件。Nothing has been installed."
  ui_print ""
  _INCOMPLETE=1
else
  _INCOMPLETE=0
fi

if [ "$CONFLICT_N" -gt 0 ]; then
  ui_print ""
  ui_print "################################################################"
  ui_print "#                                                              #"
  ui_print "#        !!!  安装已中止 / INSTALLATION ABORTED  !!!          #"
  ui_print "#                                                              #"
  ui_print "#   检测到 $CONFLICT_N 个与 HiFi SRC Bypass 争抢同一音频层的模块   #"
  ui_print "#                                                              #"
  ui_print "################################################################"
  ui_print ""
  ui_print "  冲突模块 :$CONFLICT_IDS"
  ui_print ""
  ui_print "  【为什么必须拦截 / why this is refused】"
  ui_print "  这些模块和本模块改写的是【同一层】音频通路：本模块用 bind mount 接管"
  ui_print "  audio_policy_configuration 与 USB HAL(libalsautils) 的采样率表；上面列出的"
  ui_print "  模块接管 mixer_paths 混音路径 / audio_effects 效果注册 / 自己的音效库。"
  ui_print "  两者无法互相校验：谁最后挂载谁生效，另一方的前提被静默破坏。"
  ui_print ""
  ui_print "  【真实后果 / the failure modes this prevents】"
  ui_print "   * 开机卡一屏/卡二屏：策略与 vendor HAL 能力失配后，AudioFlinger 在"
  ui_print "     AudioStreamOut::open() 得到 frame size 0 而 SIGABRT，audioserver 崩溃循环，"
  ui_print "     系统停在开机动画（Redmi K20 Pro 实测 10 份同签名 tombstone）。"
  ui_print "   * 音量调节卡死 / 音乐 App 打不开：混音路径属于另一模块时，框架层音量通"
  ui_print "     路与 AudioService 前提不一致，表现为音量键无响应、播放器无法打开输出。"
  ui_print "   * 音效库被覆盖：audio_effects 指向的库文件被另一个模块替换，音频直接失效。"
  ui_print ""
  ui_print "  【怎么做 / what to do】"
  ui_print "   1) 在 root 管理器里【卸载】或【禁用】上面列出的模块，然后重新刷入本模块；"
  ui_print "   2) 若确实要同时使用，请先只保留其中一个音频类模块，重启确认能正常进入"
  ui_print "      桌面、音量可调之后，再逐个加回，以定位冲突源。"
  ui_print "   3) 严禁带病刷入：两个模块同时改写同一音频层时，开机失败概率极高。"
  ui_print ""
  ui_print "  本次安装未写入任何文件。Nothing has been installed."
  ui_print ""
elif [ "$_INCOMPLETE" = 0 ]; then
  # the all-clear is only printed when the scan actually COMPLETED.  This is the
  # sentence the reviewer caught on an unscanned device; it is now gated on
  # evidence instead of on an empty variable.
  ui_print "- conflict check : no module competing for the audio policy / USB HAL / audio_effects layer"
  if [ -n "$DISABLED_NOTE" ]; then
    ui_print "  (present but disabled, mounts nothing, ignored):$DISABLED_NOTE"
  fi
fi

# abort() is provided by Magisk/KernelSU/APatch.  The fallback keeps the refusal
# observable for a sandbox run (and for any manager that does not define it).
if command -v abort >/dev/null 2>&1; then
  _abort() { abort "$@"; }
else
  _abort() { ui_print "$@"; exit 1; }
fi

if [ "$CONFLICT_N" -gt 0 ]; then
  _abort "! 安装中止：存在冲突音频模块，详见上方清单。"
  # abort() must not return; if it does, a hard exit still guarantees no install
  exit 1
fi

# an INCOMPLETE scan refuses on the same terms: no conflict was proven, but
# neither was the absence of one, and that is not a state this installer is
# allowed to interpret in the user's favour.
if [ "$_INCOMPLETE" = 1 ]; then
  _abort "! 安装中止：冲突检查不完整，无法确认设备干净。"
  exit 1
fi

# ------------------------------------------------------------- state dir init
# Only reached once the conflict gate has PASSED, so a refused install writes
# nothing at all (see the ORDER note above the gate).  On an upgrade the
# existing settings are kept untouched; a fresh install gets the defaults.
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

if [ -r "$OLD_STATE/config.conf" ]; then
  ui_print "- the OnePlus-13-only module's settings were found, adopting them"
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
  # `chmod 0644 <dir>/*` also hits SUBDIRECTORIES and clears their execute bit,
  # after which the WebUI's own assets (webroot/bg) cannot be opened at all --
  # the module installs and then serves a page with no background.  Directories
  # get 0755, files get 0644, decided per entry rather than by a glob.
  for _d in "$MODPATH/payload" "$MODPATH/webroot"; do
    [ -d "$_d" ] || continue
    chmod 0755 "$_d" 2>/dev/null
    for _e in "$_d"/*; do
      [ -e "$_e" ] || continue
      if [ -d "$_e" ]; then
        chmod 0755 "$_e" 2>/dev/null
        for _f in "$_e"/*; do
          [ -f "$_f" ] && chmod 0644 "$_f" 2>/dev/null
        done
      else
        chmod 0644 "$_e" 2>/dev/null
      fi
    done
  done
fi

# the bundled static mixer fallback (bin/tinymix_min, aarch64): exec bit is a
# MUST (bin/hifi only picks it when -x), and it is only shipped for arm64
# builds -- on anything else the absence is the safe "unknown" degradation.
if [ -f "$MODPATH/bin/tinymix_min" ]; then
  chmod 0755 "$MODPATH/bin/tinymix_min" 2>/dev/null
  if command -v set_perm >/dev/null 2>&1; then
    set_perm "$MODPATH/bin/tinymix_min" 0 0 0755
  fi
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
