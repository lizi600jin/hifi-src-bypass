# =============================================================================
# patch_volume.awk -- lift the TOP of the speaker/music volume curve, in place,
#                     leaving the file EXACTLY the same number of bytes
# -----------------------------------------------------------------------------
#   awk -v MARKER=HIFI_SRC_BYPASS_UNIV -v SPK_POINTS=3 -v VER=1.0 \
#       -f patch_volume.awk  <stock volume table.xml>  >  <patched.xml>
#
#   exit 0 = patched output written, at least one point was lifted
#   exit 3 = not a volume table (no <volumes> / <volume_tables> / VOLUME_CURVE)
#   exit 4 = it IS a volume table but nothing needed lifting: every one of the
#            top SPK_POINTS steps of the speaker/music curve is already 0
#            (idempotent -- re-running on our own output lands here)
#   exit 1 = internal error (the length invariant broke, or nothing parsed);
#            stdout is left EMPTY so the caller has nothing it could mount
#
# WHY THIS EXISTS
#   AOSP describes output loudness per (stream, device) as a CURVE: a list of
#         <point>index,attenuation-mB</point>
#   where the second number is not a gain, it is the amount REMOVED from full
#   scale in millibels.  A file that looks like
#
#       <volume stream="AUDIO_STREAM_MUSIC"
#               deviceCategory="DEVICE_CATEGORY_SPEAKER">
#           <point>0,-2400</point>          -24 dB at step 0
#           ...
#           <point>99,-350</point>          -3.5 dB at the top step
#           <point>100,-300</point>         -3 dB at the LAST step
#       </volume>
#
#   has a hard ceiling built into it: the volume keys climb the index until it
#   reaches 100, and step 100 is still 3 dB short of full scale, so no amount of
#   pressing volume up can recover it.  The FRAMEWORK's own idea of "maximum" is
#   the ceiling.  Rewriting the tail of that curve to 0 is what actually lifts
#   the acoustic maximum; nothing else in this module touches digital headroom
#   (the policy patcher lifts sample rates, the HAL patcher lifts the USB rate
#   table, the smart-PA layer writes amplifier registers).
#
# WHAT IT TOUCHES  (strictly, on purpose)
#     * <volume ...> whose stream is AUDIO_STREAM_MUSIC (or 1) AND whose
#       deviceCategory is DEVICE_CATEGORY_SPEAKER (or 2) -- attribute ORDER does
#       not matter, both quote styles work, one-line and multi-line tags both
#       work;
#     * <reference name="DEFAULT_DEVICE_CATEGORY_SPEAKER_VOLUME_CURVE...">, which
#       is what default_volume_tables.xml resolves the speaker music curve to on
#       ROMs that use <xi:include>d reference tables.
#   Earpiece, wired headset, bluetooth, HDMI, the assistant / ring / alarm
#   streams, DEFAULT_MEDIA_VOLUME_CURVE and every DEFAULT_*_TO_*_VOLUME_CURVE
#   conversion table are copied byte for byte.  check_volume.awk proves that
#   with a per-block byte comparison, it is not a claim.
#
# IN-PLACE, SAME LENGTH  -- the invariant the whole layer rests on
#   The patched file is bind-mounted over the vendor file and audioserver
#   re-reads it on every start, so its length must not move: a file that grew or
#   shrank is a file whose provenance we cannot vouch for.  awk has no in-place
#   edit, so the rule is blunt -- never rebuild a line, only splice the numeric
#   field, padding the replacement to the ORIGINAL WIDTH:
#
#       <point>100,-300</point>      18 bytes
#       <point>100,0   </point>      18 bytes    <- what we emit
#
#   Character data may carry trailing whitespace, and every XML parser trims it
#   (libexpat in audioserver, ElementTree in the test suite), so the parsed
#   attenuation is 0 while the byte count is untouched.  Padding is SPACES ONLY:
#   "-300" -> "0---" would not be a number at all.
#
#   The padding width is measured on the old number, which is always ASCII, so
#   this is correct under a byte-oriented awk (mawk / busybox awk on the phone)
#   without depending on locale.  The END block re-measures the whole output and
#   refuses (exit 1, empty stdout) if the invariant broke for any reason --
#   including a ROM edited by hand into a shape this scanner did not anticipate.
#
# NOTHING IS WRITTEN INTO THE FILE AS A MARKER
#   The policy patcher stamps a "HIFI_SRC_BYPASS_UNIV" comment so `is_ours()` can
#   recognise its own work with grep.  Here that is impossible without changing
#   the length, so identity is established differently: the caller keeps the
#   factory copy and runs check_volume.awk over (factory, live).  MARKER and VER
#   are accepted for call-site symmetry and appear in the log / report only.
# =============================================================================

BEGIN {
  # Trailing steps of the curve to lift.  Default 3: on a 101-step curve that is
  # the top ~3% of the index range, i.e. the last few volume-key presses, which
  # is exactly where a "it is still too quiet at maximum" complaint lives.
  # A ROM-reported 0 points to lift means "no speaker/music curve here".
  if (SPK_POINTS == "") SPK_POINTS = 3
  SPK_POINTS = SPK_POINTS + 0
  if (SPK_POINTS < 1) SPK_POINTS = 1

  if (MARKER == "") MARKER = "HIFI_SRC_BYPASS_UNIV"
  if (VER    == "") VER    = "?"

  # ---- read the file as ONE record, byte for byte ------------------------
  # The layout has to survive untouched: not just the numbers, but every space,
  # every comment and the presence or absence of a trailing newline.  A normal
  # line-oriented read cannot tell "point\n" from "point" at EOF without gawk's
  # RT, and this script must run on the phone's mawk / busybox awk.  So RS is set
  # to U+0001, a byte that CANNOT legally appear in an XML document (XML 1.0
  # section 2.2, Char production: #x9 | #xA | #xD | [#x20-#xD7FF] | ...), which
  # makes the whole file a single record -- final newline included, or excluded,
  # exactly as the ROM wrote it.  If such a byte ever does show up, the
  # length check in END refuses the file instead of guessing.
  RS = "\001"

  buf = ""      # the whole file, newlines preserved exactly
  CH  = 0       # number of points actually lifted
  NPT = 0       # number of <point> elements seen in our blocks
  NBLK = 0      # number of speaker/music blocks found
}

{ buf = buf $0 }

END {
  name = (FILENAME == "" ? "?" : FILENAME)

  # ---- 0. is this a volume table at all? -------------------------------
  # Comments are blanked (to spaces of identical width) before searching, so a
  # commented-out <volume> block or a prose mention of VOLUME_CURVE cannot make
  # a policy file look like a volume table.  Positions in `scan` are valid
  # positions in `buf` because the substitution is length-preserving.
  scan = blank_comments(buf)

  if (index(scan, "<volume_tables") == 0 && \
      index(scan, "<volumes") == 0       && \
      index(scan, "VOLUME_CURVE") == 0) {
    printf("patch_volume: %s is not a volume table (no <volumes>, no <volume_tables>, no VOLUME_CURVE)\n", name) > "/dev/stderr"
    exit 3
  }

  # ---- 1. walk the top-level <volume> / <reference> elements ------------
  out = ""
  pos = 1
  while (1) {
    ov = find_open(scan, pos, "volume")
    rf = find_open(scan, pos, "reference")

    o = 0; tag = ""
    if (ov > 0 && (rf == 0 || ov < rf))      { o = ov; tag = "volume" }
    else if (rf > 0)                          { o = rf; tag = "reference" }

    if (o == 0) { out = out substr(buf, pos); break }

    # the end of this start tag
    gt = index(substr(scan, o), ">")
    if (gt == 0) { out = out substr(buf, pos); break }
    hpos = o + gt - 1                      # absolute index of ">"
    atts = substr(scan, o + length(tag) + 1, hpos - o - length(tag) - 1)

    # a self-closing <volume ... /> carries no points; copy and move on
    if (substr(scan, hpos - 1, 1) == "/") {
      out = out substr(buf, pos, o - pos) substr(buf, o, hpos - o + 1)
      pos = hpos + 1
      continue
    }

    # the matching close tag.  <volume> and <reference> hold only <point>
    # children, so they cannot nest inside themselves and the first close tag
    # after the start tag is the right one.
    ce = index(substr(scan, hpos + 1), "</" tag)
    if (ce == 0) { out = out substr(buf, pos); break }
    cpos = hpos + ce                       # absolute index of "<" of "</tag"
    cgt  = index(substr(scan, cpos), ">")
    if (cgt == 0) { out = out substr(buf, pos); break }
    cend = cpos + cgt - 1                  # absolute index of ">" of "</tag>"

    out = out substr(buf, pos, o - pos)    # everything before the element

    if (is_our_block(tag, atts)) {
      NBLK++
      # start tag verbatim + rewritten body + close tag verbatim
      out = out substr(buf, o, hpos - o + 1)
      out = out lift_body(substr(buf, hpos + 1, cpos - hpos - 1))
      out = out substr(buf, cpos, cend - cpos + 1)
    } else {
      out = out substr(buf, o, cend - o + 1)   # whole block, untouched
    }
    pos = cend + 1
  }

  # ---- 2. the invariant, checked here rather than trusted from the caller
  if (length(out) != length(buf)) {
    printf("patch_volume: REFUSING %s -- length would change %d -> %d bytes\n", \
           name, length(buf), length(out)) > "/dev/stderr"
    exit 1
  }

  # ---- 3. nothing to do is not an error, it is exit 4 -------------------
  if (CH == 0) exit 4

  printf("%s", out)
  exit 0
}

# ---------------------------------------------------------------------------
# blank_comments: replace every <!-- ... --> with spaces of identical width.
# Used for the SEARCH copy only; the output is always spliced out of `buf`.
# ---------------------------------------------------------------------------
function blank_comments(s,   out, p, e, rest) {
  out = ""
  while (1) {
    p = index(s, "<!--")
    if (p == 0) { out = out s; break }
    out  = out substr(s, 1, p - 1)
    rest = substr(s, p)
    e    = index(rest, "-->")
    if (e == 0) { out = out spaces(length(rest)); break }
    out = out spaces(e + 2)
    s   = substr(rest, e + 3)
  }
  return out
}

function spaces(n) {
  if (n <= 0) return ""
  return sprintf("%" n "s", "")
}

# ---------------------------------------------------------------------------
# find_open: absolute position of the next "<tag" start tag at or after `from`.
# A bare index("<volume") would also hit "<volumes" and "<volume_tables", so the
# character after the name has to be one that can legally end a tag name.
# ---------------------------------------------------------------------------
function find_open(s, from, tag,   rest, p, c, cut) {
  if (from > length(s)) return 0
  cut  = from
  rest = substr(s, from)
  while ((p = index(rest, "<" tag)) > 0) {
    c = substr(rest, p + length(tag) + 1, 1)
    if (c == "" || c == " " || c == "\t" || c == "\r" || c == "\n" || \
        c == ">" || c == "/")
      return cut + p - 1
    cut  = cut + p
    rest = substr(rest, p + 1)
  }
  return 0
}

# ---------------------------------------------------------------------------
# attribute lookup on an isolated start tag.  Purpose-built: no namespace
# resolution, no entity decoding -- we only need two enum values and one name
# that AOSP always writes literally.
# ---------------------------------------------------------------------------
function attr(atts, name,   re, v) {
  re = "(^|[ \t\r\n])" name "[ \t\r\n]*=[ \t\r\n]*\"[^\"]*\""
  if (match(atts, re)) {
    v = substr(atts, RSTART, RLENGTH)
    sub(/^[^"]*"/, "", v)          # up to and including the opening quote
    sub(/"[ \t\r\n]*$/, "", v)     # the closing quote (and its trailing ws)
    return v
  }
  re = "(^|[ \t\r\n])" name "[ \t\r\n]*=[ \t\r\n]*'[^']*'"
  if (match(atts, re)) {
    v = substr(atts, RSTART, RLENGTH)
    sub(/^[^']*'/, "", v)
    sub(/'[ \t\r\n]*$/, "", v)
    return v
  }
  return ""
}

# which blocks do we own?  See the header.  Numeric enum spellings (1 / 2) are
# legal in the framework's own parser and mean the same thing.
function is_our_block(tag, atts,   s, d, n) {
  if (tag == "volume") {
    s = attr(atts, "stream")
    d = attr(atts, "deviceCategory")
    if (s != "AUDIO_STREAM_MUSIC" && s != "1")              return 0
    if (d != "DEVICE_CATEGORY_SPEAKER" && d != "2")         return 0
    return 1
  }
  if (tag == "reference") {
    n = attr(atts, "name")
    # prefix match: some ROMs decorate the curve name with a suffix, and the
    # exact AOSP spelling must of course match too
    if (n ~ /^DEFAULT_DEVICE_CATEGORY_SPEAKER_VOLUME_CURVE/) return 1
    return 0
  }
  return 0
}

# the index of a <point> segment, or "" if it is not a well-formed one
function point_index(seg,   t) {
  t = seg
  sub(/^<point[ \t\r\n]*>/, "", t)
  sub(/,.*$/, "", t)
  sub(/[ \t\r\n]+$/, "", t)
  if (t !~ /^[0-9]+$/) return ""
  return t
}

# ---------------------------------------------------------------------------
# lift_body: rewrite the tail of one speaker/music curve.
#
# The tail is chosen by INDEX VALUE, not by file order: AOSP generators emit the
# points in ascending index order, but a hand-sorted ROM file may not, and "the
# last three steps" means the three highest indices either way.
# ---------------------------------------------------------------------------
function lift_body(b,   rest, seg, idx, cnt, i, j, t, from, res) {
  # ---- pass 1: index inventory ----------------------------------------
  cnt = 0
  split("", PIDX)
  rest = b
  while (match(rest, /<point[ \t\r\n]*>[^<]*<\/point[ \t\r\n]*>/)) {
    seg = substr(rest, RSTART, RLENGTH)
    idx = point_index(seg)
    if (idx != "") { cnt++; PIDX[cnt] = idx + 0 }
    rest = substr(rest, RSTART + RLENGTH)
  }
  if (cnt == 0) return b          # a curve with no points: nothing to lift

  NPT += cnt

  # insertion sort -- <= 101 entries, and this keeps the file dependency-free
  for (i = 2; i <= cnt; i++) {
    t = PIDX[i]
    for (j = i - 1; j >= 1 && PIDX[j] > t; j--) PIDX[j + 1] = PIDX[j]
    PIDX[j + 1] = t
  }
  from = cnt - SPK_POINTS + 1
  if (from < 1) from = 1
  split("", TAIL)
  for (i = from; i <= cnt; i++) TAIL[PIDX[i]] = 1

  # ---- pass 2: splice, everything else byte-identical -------------------
  res  = ""
  rest = b
  while (match(rest, /<point[ \t\r\n]*>[^<]*<\/point[ \t\r\n]*>/)) {
    seg  = substr(rest, RSTART, RLENGTH)
    res  = res substr(rest, 1, RSTART - 1)
    rest = substr(rest, RSTART + RLENGTH)
    idx  = point_index(seg)
    if (idx != "" && ((idx + 0) in TAIL)) {
      t = lift_one(seg)
      if (t != "") { res = res t; CH++; continue }
    }
    res = res seg
  }
  return res rest
}

# ---------------------------------------------------------------------------
# lift_one: the single mutation this script performs.
# Returns the replacement segment (same length) or "" when no change is needed.
#
#   <point>100,-300</point>
#           ^^^^ ^^^^            head (through the comma and its whitespace)
#                 ^^^^            the attenuation token -> "0" + pad spaces
#                     ^^^^^^^^^^  tail (whitespace + </point>)
# ---------------------------------------------------------------------------
function lift_one(seg,   a, rest, cpos, r2, w, dbstart, dblen, db, head, tail, out, pad) {
  if (!match(seg, /^<point[ \t\r\n]*>/)) return ""
  a    = RLENGTH
  rest = substr(seg, a + 1)
  cpos = index(rest, ",")
  if (cpos == 0) return ""

  # skip the whitespace that may follow the comma, counted char by char so this
  # never depends on an awk's handling of empty regex matches
  r2 = substr(rest, cpos + 1)
  w  = 0
  while (substr(r2, w + 1, 1) ~ /^[ \t\r\n]$/) w++
  dbstart = a + cpos + w + 1

  if (!match(substr(seg, dbstart), /^[-+]?[0-9]+/)) return ""
  dblen = RLENGTH
  db    = substr(seg, dbstart, dblen)

  if (db !~ /^-/)      return ""   # not an attenuation -> not ours to touch
  if (db + 0 == 0)     return ""   # already full scale (this is the exit-4 path)

  head = substr(seg, 1, dbstart - 1)
  tail = substr(seg, dbstart + dblen)

  out = "0"
  pad = dblen - 1
  while (pad-- > 0) out = out " "
  return head out tail
}
