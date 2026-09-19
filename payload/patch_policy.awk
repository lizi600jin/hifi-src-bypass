# =============================================================================
# patch_policy.awk -- generic Android audio policy XML patcher
# -----------------------------------------------------------------------------
#   awk -v MARKER=... -v MIXER=48000 -v CEIL=384000 -v BITS=32 -v VER=1.1 \
#       -v HIFI=192000 \
#       -v STOCKPATH=/odm/etc/audio/audio_module_config_primary.xml \
#       -f patch_policy.awk  <stock.xml>  >  <patched.xml>
#
#   exit 0 = patched output written, at least one port was modified
#   exit 3 = not an audio policy file (no profile line with a known format)
#   exit 4 = recognised, but nothing here needed changing
#
#   HIFI   : rate for a *dynamic* vendor HiFi mixPort (e.g. "hifi_playback").
#            "auto" / unset = leave it alone (stock: the port is [dynamic], the
#            HAL reports the DAC's own maximum and APM pins the port there).
#            A number = give the port a *static* profile with that single rate,
#            which overrides the dynamic query.  Verified on a Redmi K20 Pro
#            (Android 16): the live port went 384000 -> 192000 Hz, so a 192k
#            source plays with zero resampling instead of an upsampling 2x.
#
# WHY THIS EXISTS
#   The previous generation of this module shipped a *device* template: a full
#   copy of the OnePlus 13 factory policy with @TOKEN@ placeholders, expanded
#   with sed.  That can never work on another phone -- different file paths,
#   different port names, a completely different XML dialect.
#
#   This patcher is rule based and runs on the phone, against the phone's own
#   factory file.  It works the dialect out by itself:
#
#     QTI / Qualcomm AIDL (ColorOS 13+, HyperOS, ...)
#        <profile samplingRates="..." channelLayouts="..." formatType="PCM"
#                 pcmType="INT_16_BIT" />
#        <devicePort tagName="usb_headset" deviceType="OUT_HEADSET"
#                    connection="usb" role="sink">
#
#     AOSP / HIDL (Android 8 - 12, MIUI, Pixel, most MediaTek)
#        <profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
#                 samplingRates="..." channelMasks="..."/>
#        <devicePort tagName="USB Headset Out"
#                    type="AUDIO_DEVICE_OUT_USB_HEADSET" role="sink">
#
# WHAT IT CHANGES  (nothing else -- the file skeleton stays byte-identical)
#   * every PCM <profile> inside a USB / wired / DIRECT port gets its
#     samplingRates re-capped to the configured ceiling
#   * missing 24 / 32-bit profiles are APPENDED by cloning an existing PCM
#     profile line of the same port, so attribute order, channel masks and
#     indentation are always the phone's own
#   * speaker / earpiece (and the primary mixer ports) are aligned to the
#     configured mixer rate, and only when that differs from the factory value
#
# WHAT IT NEVER DOES
#   * never adds, removes or renames a mixPort / devicePort / route
#   * never touches compress offload (hardware FLAC/APE), mmap_no_irq, raw,
#     haptics, spatializer, telephony / voip, bluetooth, hdmi, or any mic port
#   * never removes a bit depth or a rate the vendor already declared
#     (except rates above the requested ceiling, which is the whole point)
# =============================================================================

BEGIN {
  DIRECT_POOL = "8000 11025 12000 16000 22050 24000 32000 44100 48000 64000 88200 96000 128000 176400 192000 352800 384000"
  DEV_POOL    = "44100 48000 64000 88200 96000 128000 176400 192000 352800 384000"
  N   = 0
  ON  = 0
  AN  = 0
  ADDN = 0
  PORTS = ""
  NPORT = 0
  CHANGED = 0
  BREF = 1
  # MIX_KEEP_ALL is 0 by default: a mixer port is collapsed to the single
  # configured rate, because AudioPolicyManager takes the MAX of the list.
  # The caller may set -v MIX_KEEP_ALL=1 to additionally retain the factory
  # rates, which keeps e.g. 48 kHz sources reachable at 48 kHz.
  if (MIX_KEEP_ALL == "") MIX_KEEP_ALL = 0
  RSEP = " "         # replaced once the dialect is known (see END)
  # HIFI defaults to "auto": leave dynamic vendor HiFi mixPorts untouched.
  # A numeric value turns them into statically profiled ports (see the header
  # comment) -- the only lever that reaches the port USB audio actually plays
  # through on Qualcomm/OnePlus style ROMs.
  if (HIFI == "") HIFI = "auto"
}

{ N++; L[N] = $0 }

# ============================================================ value helpers
function attr(s, key,   pat, i, j) {
  pat = key "=\""
  i = index(s, pat)
  if (i == 0) return ""
  i = i + length(pat)
  j = i
  while (j <= length(s) && substr(s, j, 1) != "\"") j++
  if (j > length(s)) return ""
  return substr(s, i, j - i)
}

function setattr(s, key, val,   pat, i, j) {
  pat = key "=\""
  i = index(s, pat)
  if (i == 0) return s
  i = i + length(pat)
  j = i
  while (j <= length(s) && substr(s, j, 1) != "\"") j++
  if (j > length(s)) return s
  return substr(s, 1, i - 1) val substr(s, j)
}

function out(s) { ON++; O[ON] = s }

# --------------------------------------------------------------------------
# rate set helpers.  RC / RSET are the workspace; every user of them must be
# sequenced so no helper is called while a set is still needed.
function rs_add(r,   k) {
  if (r == "" || r !~ /^[0-9]+$/) return
  for (k = 1; k <= RC; k++) if (RSET[k] == r) return
  RC++
  RSET[RC] = r
}

# Which separator does THIS file use for a rate list?  The QTI/AIDL dialect
# writes spaces ("32000 44100 48000") while the AOSP/HIDL dialect writes
# commas ("8000,11025,...").  Re-emitting an AOSP list with spaces makes
# AudioPolicyManager parse the whole thing as ONE bogus rate and reject the
# config -- audioserver then never brings AudioPolicyService up and the phone
# goes silent.  Verified the hard way on a Redmi K20 Pro (Android 16).
# Derived from the list we were handed, so a file that mixes styles stays
# internally consistent.
function rs_sort_join(   i, j, key, s) {
  for (i = 2; i <= RC; i++) {
    key = RSET[i] + 0
    j = i - 1
    while (j >= 1 && (RSET[j] + 0) > key) { RSET[j + 1] = RSET[j]; j-- }
    RSET[j + 1] = key
  }
  s = ""
  for (i = 1; i <= RC; i++) s = s (i > 1 ? RSEP : "") RSET[i]
  return s
}

# union(factory list, pool), drop everything above `cap`, ascending
function make_rates(orig, pool, cap,   a, n, i) {
  RC = 0
  n = split(orig, a, /[ \t]+/)
  for (i = 1; i <= n; i++) if (a[i] ~ /^[0-9]+$/ && (a[i] + 0) <= cap) rs_add(a[i])
  n = split(pool, a, /[ \t]+/)
  for (i = 1; i <= n; i++) if (a[i] ~ /^[0-9]+$/ && (a[i] + 0) <= cap) rs_add(a[i])
  if (RC == 0) return ""
  return rs_sort_join()
}

# union(factory list, {r}), ascending -- used for speaker / earpiece, where the
# position inside the list carries no meaning
function add_rate(orig, r,   a, n, i) {
  RC = 0
  n = split(orig, a, /[ \t]+/)
  for (i = 1; i <= n; i++) rs_add(a[i])
  rs_add(r)
  if (RC == 0) return ""
  return rs_sort_join()
}

# THE mixer-rate fix.  AudioPolicyManager::pickAudioProfile() picks the
# *maximum* sampling rate for a mixed output (only Direct / Offload take the
# minimum), so merely prepending the wanted rate to the list does nothing --
# 48000 is still the max and still wins.  The wanted rate therefore has to
# become the ONLY rate in the list.  Verified on a OnePlus 13 (Android 16):
# `44100 48000` -> the live DEEP_BUFFER MixerThread stayed at 48000 Hz;
# `44100`      -> it dropped to 44100 Hz.
#
# MIX_KEEP_ALL=1 keeps the factory rates alongside the wanted one.  That is
# only meaningful for a *device* port (a sink), which never picks by max; on a
# mixer mixPort it would silently undo the whole fix, so the caller leaves it
# at 0 for mixPorts.
function mixer_only(orig, m,   a, n, i) {
  RC = 0
  rs_add(m)
  if (MIX_KEEP_ALL) {
    n = split(orig, a, /[ \t]+/)
    for (i = 1; i <= n; i++) rs_add(a[i])
    if (RC == 0) return ""
    return rs_sort_join()
  }
  return m
}

# --------------------------------------------------------------------------
# what bit depth does this format token represent?  0 = not a PCM depth.
# FLOAT deliberately does NOT count as a 32-bit slot: a USB Audio Class device
# that wants S32_LE needs AUDIO_FORMAT_PCM_32_BIT / INT_32_BIT, and a float
# profile alone does not give it that.  That keeps the 32-bit tier honest.
function fmt_bits(tok) {
  if (tok == "") return 0
  if (tok ~ /PCM_16_BIT/ || tok == "INT_16_BIT") return 16
  if (tok == "INT_24_BIT" || tok == "FIXED_Q_8_24") return 24
  if (tok ~ /PCM_24_BIT_PACKED/ || tok ~ /PCM_8_24_BIT/) return 24
  if (tok == "INT_32_BIT" || tok ~ /PCM_32_BIT/) return 32
  return 0
}

function fmt_name(bits) {
  if (DIA == "qti") {
    if (bits == 16) return "INT_16_BIT"
    if (bits == 24) return "INT_24_BIT"
    return "INT_32_BIT"
  }
  if (bits == 16) return "AUDIO_FORMAT_PCM_16_BIT"
  if (bits == 24) return "AUDIO_FORMAT_PCM_24_BIT_PACKED"
  return "AUDIO_FORMAT_PCM_32_BIT"
}

function is_profile(i) { return CLIVE[i] ~ /^[ \t]*<profile[ \t>]/ }

# The same test for an index *inside the currently buffered block*.  BREF is
# the absolute line number the block starts at.  Mixing the two up silently
# makes every block look profile-free, which would only ever surface as "the
# module installed fine but does nothing".
function is_pblk(i) { return CLIVE[BREF + i - 1] ~ /^[ \t]*<profile[ \t>]/ }

# ============================================================ pre-processing
# Mark every line with the part that is real markup, comments removed.
# The factory files ship <!-- ... --> blocks that hold a *second*, disabled
# copy of the profiles (vendor pseudo #ifdef/#else).  Rewriting or counting
# those would be wrong, so they have to be invisible to everything below.
function mark_comments(   i, inc, ln, pos, live, p, rest) {
  inc = 0
  for (i = 1; i <= N; i++) {
    ln = L[i]
    pos = 1
    live = ""
    while (pos <= length(ln)) {
      if (inc) {
        rest = substr(ln, pos)
        p = index(rest, "-->")
        if (p == 0) { pos = length(ln) + 1 }
        else { pos = pos + p + 2; inc = 0 }
      } else {
        rest = substr(ln, pos)
        p = index(rest, "<!--")
        if (p == 0) { live = live rest; pos = length(ln) + 1 }
        else { live = live substr(rest, 1, p - 1); pos = pos + p + 3; inc = 1 }
      }
    }
    CLIVE[i] = live
  }
}

# the factory mixer rate: first sampling rate of the primary mixer mixPort
function factory_mix(   i, k, head, name, flags, v, a) {
  for (i = 1; i <= N; i++) {
    if (CLIVE[i] !~ /^[ \t]*<mixPort[ \t>]/) continue
    head = L[i]
    if (attr(head, "role") != "source") continue
    name  = attr(head, "name")
    flags = attr(head, "flags")
    if (!((flags ~ /PRIMARY/ && flags !~ /RAW/) || name ~ /^(low_latency|deep_buffer)/)) continue
    for (k = i + 1; k <= N; k++) {
      if (CLIVE[k] ~ /<\/mixPort>/) break
      if (!is_profile(k)) continue
      v = attr(L[k], "samplingRates")
      split(v, a, /[ \t]+/)
      if (a[1] ~ /^[0-9]+$/) return a[1]
    }
  }
  return 48000
}

# ============================================================ classification
# devicePort (role="sink") classifier
#   "usb"   -> the dongle: the port this module exists for
#   "wired" -> 3.5 mm / analog: best effort, same treatment
#   "mixer" -> speaker / earpiece: only the mixer rate gets aligned
#   ""      -> leave alone
function dev_class(head,   typ, tag, conn, role, tl) {
  typ  = attr(head, "type")
  tag  = attr(head, "tagName")
  conn = attr(head, "connection")
  role = attr(head, "role")
  tl   = tolower(tag)

  # Never touch a capture port.  Raising a microphone port's sampling rates
  # cannot help playback, and a capture profile the HAL never declared can make
  # recording fail.  `role="source"` is the AIDL spelling; `AUDIO_DEVICE_IN_*`
  # is the HIDL spelling.  The name test is a belt-and-braces fallback for the
  # rare policy that omits `role`.
  if (role == "source") return ""
  if (typ ~ /_IN_/) return ""
  if (tl ~ /(^|[ _-])mic($|[ _-])/ || tl ~ /input/) return ""

  if (typ != "") {                              # AOSP / HIDL style
    if (typ !~ /_OUT_/) return ""               # outputs only
    if (typ ~ /USB_ACCESSORY/) return ""
    if (typ ~ /USB/) return "usb"
    if (typ ~ /WIRED_HEADSET/ || typ ~ /WIRED_HEADPHONE/) return "wired"
    if (typ ~ /SPEAKER/ || typ ~ /EARPIECE/) return "mixer"
    return ""
  }

  # QTI / AIDL style: no `type`, but there is `connection`
  if (conn ~ /^(bt|hdmi|ip|virtual|proxy|telephony|remote|aux|spdif)/) return ""
  if (conn == "usb" || tag ~ /usb/) return "usb"
  if (tag ~ /speaker/ || tag ~ /earpiece/) return "mixer"
  if (tag ~ /wired|headset|headphone/) return "wired"
  return ""
}

function mix_class(B, bn,   name, role, flags, i) {
  name  = attr(B[1], "name")
  role  = attr(B[1], "role")
  # `flags` is usually on the opening tag, but several ROMs -- the Redmi K20
  # Pro's factory file among them -- wrap it onto the next line.  Classifying
  # from the head line alone silently skipped every such port (direct_pcm and
  # voip_rx included), so scan the whole block for it.  Nothing else inside a
  # mixPort carries a flags attribute, so the first hit is the port's own.
  flags = ""
  for (i = 1; i <= bn && flags == ""; i++) flags = attr(B[i], "flags")
  if (role != "source") return ""
  if (flags ~ /DIRECT/ && flags !~ /COMPRESS_OFFLOAD|MMAP_NOIRQ|SPATIALIZER|OFFLOAD|RAW|VOIP/) return "direct"
  if ((flags ~ /PRIMARY/ && flags !~ /RAW/) || name ~ /^(low_latency|deep_buffer)/) return "mixer"
  # A dynamic vendor HiFi port ("hifi_playback"): no flags at all, and the name
  # carries "hifi".  Only touched when the caller asked for a static rate --
  # this is the port USB audio actually plays through on Qualcomm/OnePlus-style
  # ROMs, and it is the one port neither MIXER nor the HAL rate table can reach.
  if (HIFI ~ /^[0-9]+$/ && flags == "" && name ~ /[Hh]ifi/) return "hifi"
  return ""
}

# ============================================================ block rewriting
#
# Fill in a *dynamic* vendor HiFi mixPort (e.g. Qualcomm/OnePlus "hifi_playback")
# with a static profile, so AudioPolicyManager stops pinning it to whatever the
# DAC advertises as its maximum.  The stock port is self-closing and profile
# free, which is exactly why the policy asks the HAL at run time and then takes
# the maximum; with a static profile in the file it takes ours instead
# (verified on a Redmi K20 Pro, Android 16: the live port went 384000 -> 192000
# Hz, so a 192k source plays with zero resampling instead of an upsampling 2x).
#
# A port the vendor already gave profiles to is NOT dynamic -- leave it alone,
# we would only be guessing at capabilities the HAL knows better than we do.
function emit_hifi(bn, name,   i, k, ind, head, op, b, prof, np, PLN) {
  # dynamic means: not a single <profile> anywhere inside the block
  for (i = 1; i <= bn; i++) if (is_pblk(i)) { for (i = 1; i <= bn; i++) out(B[i]); return }

  head = B[1]
  ind = head
  sub(/[^ \t].*$/, "", ind)          # the port's own indentation
  if (ind == "") ind = "                "

  np = 0
  for (b = 16; b <= 32; b += 8) {
    if ((BITS + 0) < b) continue     # respect the user's bit-depth tier
    if (DIA == "qti")
      prof = ind "    <profile samplingRates=\"" HIFI "\" channelLayouts=\"LAYOUT_STEREO\" formatType=\"PCM\" pcmType=\"" fmt_name(b) "\" />"
    else
      prof = ind "    <profile name=\"\" format=\"" fmt_name(b) "\" samplingRates=\"" HIFI "\" channelMasks=\"AUDIO_CHANNEL_OUT_STEREO\"/>"
    np++; PLN[np] = prof
  }
  if (np == 0) { for (i = 1; i <= bn; i++) out(B[i]); return }

  if (bn == 1 && head ~ /\/>[ \t]*$/) {
    # self-closing:  <mixPort ... />  ->  <mixPort ...> profiles </mixPort>
    op = head
    sub(/[ \t]*\/>[ \t]*$/, ">", op)
    out(op)
    for (k = 1; k <= np; k++) out(PLN[k])
    out(ind "</mixPort>")
  } else {
    # already has a closer: insert the profiles just before </mixPort>
    for (i = 1; i <= bn; i++) {
      if (i == bn && CLIVE[BREF + i - 1] ~ /<\/mixPort>/) for (k = 1; k <= np; k++) out(PLN[k])
      out(B[i])
    }
  }

  CHANGED = 1
  NPORT++
  PORTS = PORTS (PORTS == "" ? "" : ",") "mix:" name "=HIFI"
}

# Work in *element* units, never in physical-line units: Qualcomm's AOSP-style
# files wrap a single <profile> over four lines, so a line-oriented rewriter
# would never even see the samplingRates attribute.  The original line breaks
# and indentation are preserved, so the diff stays minimal.
function emit_block(bn, cls, kind, name,
                    i, k, e, ne, ln, ft, tok, ispcm, fpcm,
                    rates, rline, pb16, pb24, pb32, old, nw, tag, v, b,
                    bs, be, cn, lastend) {
  if (cls == "") { for (i = 1; i <= bn; i++) out(B[i]); return }
  if (cls == "hifi") { emit_hifi(bn, name); return }

  for (i = 1; i <= bn; i++) T[i] = B[i]

  ne = 0; fpcm = 0; lastend = 0
  pb16 = 0; pb24 = 0; pb32 = 0

  # ---- 1. locate the profile elements and rewrite their rate lists --------
  i = 1
  while (i <= bn) {
    if (!is_pblk(i)) { i++; continue }
    bs = i
    be = i
    while (be < bn && CLIVE[BREF + be - 1] !~ /\/>/) be++
    ne++
    ESTART[ne] = bs
    EEND[ne] = be
    lastend = be

    ft = ""; tok = ""; rates = ""; rline = 0; EFL[ne] = 0
    for (k = bs; k <= be; k++) {
      ln = B[k]
      if (ft == "")    { v = attr(ln, "formatType");    if (v != "") ft = v }
      if (tok == "")   { v = attr(ln, FKEY);            if (v != "") { tok = v; EFL[ne] = k } }
      if (rates == "") { v = attr(ln, "samplingRates"); if (v != "") { rates = v; rline = k } }
    }
    ispcm = (ft == "" || ft ~ /PCM/) && tok != "" && tok !~ /NON_PCM/
    if (ispcm) {
      if (fpcm == 0) fpcm = ne
      b = fmt_bits(tok)
      if (b == 16) pb16 = 1
      else if (b == 24) pb24 = 1
      else if (b == 32) pb32 = 1
    }

    if (rates != "" && rline > 0) {
      nw = ""
      if (cls == "direct" || cls == "usb" || cls == "wired") {
        nw = make_rates(rates, (cls == "direct" ? DIRECT_POOL : DEV_POOL), CEIL)
      } else if (cls == "mixer" && ispcm && (MIXER + 0) != (FMIX + 0)) {
        nw = (kind == "mix") ? mixer_only(rates, MIXER) : add_rate(rates, MIXER)
      }
      if (nw != "" && nw != rates) {
        T[rline] = setattr(T[rline], "samplingRates", nw)
        if (T[rline] != B[rline]) CHANGED = 1
      }
    }
    i = be + 1
  }

  # ---- 2. append the bit depths the factory did not declare.  The clone is
  #         a copy of the port's own first PCM profile, so attribute order,
  #         channel masks, indentation and line breaks are the phone's, not
  #         something we invented.
  cn = 0
  if (fpcm > 0 && cls != "mixer") {
    bs = ESTART[fpcm]; be = EEND[fpcm]
    for (b = 24; b <= 32; b += 8) {
      if ((BITS + 0) < b) continue
      if (b == 24 && pb24 == 1) continue
      if (b == 32 && pb32 == 1) continue
      v = fmt_name(b)
      cn = 0
      for (k = bs; k <= be; k++) {
        ln = T[k]
        if (k == EFL[fpcm]) ln = setattr(ln, FKEY, v)
        cn++; CLN[cn] = ln
      }
      for (k = 1; k <= cn; k++) ADD[++AN] = CLN[k]
      ADDN = AN
      CHANGED = 1
    }
  }

  for (i = 1; i <= bn; i++) {
    out(T[i])
    if (i == lastend && ADDN > 0) {
      for (k = 1; k <= ADDN; k++) out(ADD[k])
      ADDN = 0; AN = 0
    }
  }

  NPORT++
  tag = kind ":" name
  if (cls == "direct") tag = tag "=DIRECT"
  else if (cls == "mixer") tag = tag "=MIXER"
  PORTS = PORTS (PORTS == "" ? "" : ",") tag
}

# ============================================================ main
END {
  mark_comments()

  qti = 0; aosp = 0
  for (i = 1; i <= N; i++) {
    if (CLIVE[i] ~ /pcmType="/) qti++
    else if (CLIVE[i] ~ /format="AUDIO_FORMAT_/) aosp++
  }
  if (qti == 0 && aosp == 0) {
    printf("patch_policy: no <profile> line with a known format attribute\n") > "/dev/stderr"
    exit 3
  }
  DIA  = (qti >= aosp) ? "qti" : "aosp"
  FKEY = (DIA == "qti") ? "pcmType" : "format"
  # The rate-list separator is a per-FILE style, not a dialect rule: the AOSP
  # documentation writes spaces, yet the Redmi K20 Pro's HIDL file uses commas
  # and its compressed_offload profile mixes spaces into a comma file.  Infer
  # the style from the document itself: if any samplingRates attribute carries
  # a comma, the file's dominant style is commas; otherwise spaces (which is
  # what a [dynamic]-only or space-styled file wants).  Getting this wrong on
  # an AOSP file makes AudioPolicyManager read the whole list as one bogus
  # rate, which takes the phone's audio down with it.
  RSEP = " "
  for (i = 1; i <= N; i++) {
    if (CLIVE[i] ~ /samplingRates="[^"]*,/) { RSEP = ","; break }
  }
  FMIX = factory_mix()
  if (FMIX !~ /^[0-9]+$/) FMIX = 48000

  i = 1
  while (i <= N) {
    # drop a provenance header from a previous run, so patching a patched file
    # is idempotent (defence in depth: the controller always patches the
    # archived factory copy, but a stale -- or hand-edited -- file must not
    # silently accumulate headers)
    if (index(L[i], MARKER) > 0 && CLIVE[i] ~ /^[ \t]*$/) { i++; continue }

    if (CLIVE[i] ~ /^[ \t]*<mixPort[ \t>]/) {
      BREF = i
      bn = 0
      if (CLIVE[i] ~ /\/>[ \t]*$/) {
        # self-closing single-line port (e.g. stock "<mixPort name="hifi_playback"
        # role="source" />").  Without this branch the scanner would run on
        # until the NEXT port's </mixPort> and swallow it, silently skipping
        # every port in between.
        bn = 1; B[1] = L[i]; i++
      } else {
        while (i <= N) {
          bn++; B[bn] = L[i]
          if (CLIVE[i] ~ /<\/mixPort>/) { i++; break }
          i++
        }
      }
      emit_block(bn, mix_class(B, bn), "mix", attr(B[1], "name"))
      continue
    }
    if (CLIVE[i] ~ /^[ \t]*<devicePort[ \t>]/) {
      BREF = i
      bn = 0
      if (CLIVE[i] ~ /\/>[ \t]*$/) {
        bn = 1; B[1] = L[i]; i++          # same self-closing case, same trap
      } else {
        while (i <= N) {
          bn++; B[bn] = L[i]
          if (CLIVE[i] ~ /<\/devicePort>/) { i++; break }
          i++
        }
      }
      role = attr(B[1], "role")
      cls = (role == "" || role == "sink") ? dev_class(B[1]) : ""
      tag = attr(B[1], "tagName"); if (tag == "") tag = attr(B[1], "type")
      emit_block(bn, cls, "dev", tag)
      continue
    }
    out(L[i])
    i++
  }

  hdr1 = "<!-- " MARKER " v" VER " | dialect=" DIA " | stock=" STOCKPATH " | mixer=" MIXER " ceiling=" CEIL " bits=" BITS " hifi=" HIFI " | generated, do not hand edit -->"
  hdr2 = "<!-- " MARKER " | ports=" PORTS " | repo: android audio src bypass -->"

  start = 1
  if (ON >= 1 && O[1] ~ /^[ \t]*<\?xml/) {
    print O[1]
    start = 2
  }
  print hdr1
  print hdr2
  for (i = start; i <= ON; i++) print O[i]

  if (CHANGED == 0) {
    printf("patch_policy: dialect=%s, nothing to change in this file\n", DIA) > "/dev/stderr"
    exit 4
  }
  exit 0
}
