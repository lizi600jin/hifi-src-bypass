# =============================================================================
# check_volume.awk -- prove a patched volume table is the factory file with only
#                     the speaker/music curve tail lifted
# -----------------------------------------------------------------------------
#   awk -v SPK_POINTS=3 -f check_volume.awk  <stock.xml>  <patched.xml>
#
#   exit 0 = the patch is safe to mount
#   exit 1 = it is NOT -> the caller must refuse to mount and keep the factory
#            file (bin/hifi's target_applied() / apply_mount path)
#
# This is the safety net that makes "patch loudness on a phone we have never
# seen" acceptable at all.  patch_volume.awk claims to touch four characters per
# lifted point; this file proves it, on the phone, from the two files themselves:
#
#   1. same byte length -- the bind mount must present a file indistinguishable
#      in size from the factory one (see the header of patch_volume.awk);
#   2. the same number of <volume>/<reference> blocks, in the same order, with
#      the same tags;
#   3. every byte outside those blocks is identical;
#   4. every block that is NOT the speaker/music curve is byte-identical --
#      this is the important one: an earpiece, wired, bluetooth or HDMI curve
#      that moved by one character is a defect, not a style choice;
#   5. inside the speaker/music curves: the point COUNT and the INDEX SEQUENCE
#      are unchanged (no step added, none removed, none reordered), and only
#      the attenuation token differs;
#   6. the top SPK_POINTS steps of those curves are now exactly 0.
#
# Exit 1 on anything unexpected, with a one-line reason on stderr, so the caller
# can log it verbatim.
# =============================================================================

BEGIN {
  FILEN = 0
  # one record per FILE, byte exact -- see the same note in patch_volume.awk.
  # A trailing newline that the factory file has (or lacks) must be compared,
  # not normalised away, because the length assertion depends on it.
  RS = "\001"
  if (SPK_POINTS == "") SPK_POINTS = 3
  SPK_POINTS = SPK_POINTS + 0
}

{ FILEN++; BUF[FILEN] = $0 }

END {
  if (FILEN != 2) {
    printf("check_volume: need exactly 2 files (stock, patched), got %d\n", FILEN) > "/dev/stderr"
    exit 1
  }
  fail = 0

  # ---- 1. byte length ---------------------------------------------------
  L1 = length(BUF[1]); L2 = length(BUF[2])
  if (L1 != L2) {
    printf("FAIL byte length: stock %d != patched %d\n", L1, L2) > "/dev/stderr"
    fail = 1
  }

  scan(1)
  scan(2)

  # ---- 2. block inventory ----------------------------------------------
  if (NB1 != NB2) {
    printf("FAIL block count: stock %d != patched %d\n", NB1, NB2) > "/dev/stderr"
    fail = 1
  }
  if (OUT1 != OUT2) {
    printf("FAIL: the text OUTSIDE the volume/reference blocks differs\n") > "/dev/stderr"
    fail = 1
  }

  lim = (NB1 < NB2 ? NB1 : NB2)
  for (i = 1; i <= lim; i++) {
    # ---- 3. same block, same tag, same ownership --------------------
    if (TAG1[i] != TAG2[i]) {
      printf("FAIL block %d: tag <%s> became <%s>\n", i, TAG1[i], TAG2[i]) > "/dev/stderr"
      fail = 1
      continue
    }
    if (OUR1[i] != OUR2[i]) {
      printf("FAIL block %d: <%s> speaker/music classification changed\n", i, TAG1[i]) > "/dev/stderr"
      fail = 1
      continue
    }

    # ---- 4. blocks we do not own must be byte-identical --------------
    if (!OUR1[i]) {
      if (BODY1[i] != BODY2[i]) {
        printf("FAIL block %d <%s %s>: must not be touched, but changed\n", \
               i, TAG1[i], LABEL1[i]) > "/dev/stderr"
        fail = 1
      }
      continue
    }

    # ---- 5. our curves: same shape, same indices, only the tail moved
    if (NPT1[i] != NPT2[i]) {
      printf("FAIL block %d <%s>: point count %d != %d\n", i, TAG1[i], NPT1[i], NPT2[i]) > "/dev/stderr"
      fail = 1
      continue
    }
    bad = 0
    for (j = 1; j <= NPT1[i]; j++) {
      if (IDX1[i, j] != IDX2[i, j]) {
        if (bad < 3)
          printf("FAIL block %d <%s>: point %d index %s != %s\n", i, TAG1[i], j, IDX1[i, j], IDX2[i, j]) > "/dev/stderr"
        bad++
      }
    }
    if (bad) { fail = 1; continue }

    # skeleton = the body with every attenuation token blanked; everything
    # else (indentation, attribute-free markup, ordering) must match exactly
    if (SKEL1[i] != SKEL2[i]) {
      printf("FAIL block %d <%s>: markup around the attenuation changed\n", i, TAG1[i]) > "/dev/stderr"
      fail = 1
    }

    # ---- 6. the top SPK_POINTS steps must be 0 dB -------------------
    n = NPT2[i]
    if (n == 0) continue
    if (SPK_POINTS > n) from = 1; else from = n - SPK_POINTS + 1
    for (j = from; j <= n; j++) {
      if (DB2[i, j] != "0") {
        printf("FAIL block %d <%s>: step %s is %s, expected 0\n", \
               i, TAG1[i], IDX2[i, j], DB2[i, j]) > "/dev/stderr"
        fail = 1
      }
    }
  }

  if (fail) exit 1
  exit 0
}

# ---------------------------------------------------------------------------
# scan(f): fill the per-file arrays.  Everything is indexed by file number, so
# the two scans never share state; the comparison in END walks them side by side.
#   TAG[f,i]   element name ("volume" / "reference")
#   OUR[f,i]   1 = a speaker/music curve, 0 = copied through untouched
#   BODY[f,i]  the element text between the start tag and the close tag
#   NPT[f,i]   number of <point> children
#   IDX[f,i,j], DB[f,i,j]  index and attenuation token of each point
#   SKEL[f,i]  BODY with every attenuation token replaced by "@"
#   OUT[f]     all text outside those blocks, concatenated
# ---------------------------------------------------------------------------
function scan(f,   s, pos, o, ov, rf, tag, gt, hpos, atts, ce, cpos, cgt, cend, body) {
  s = BUF[f]
  scan_ = blank_comments(s)
  NPT[f] = 0; OUT[f] = ""; NB[f] = 0
  pos = 1
  while (1) {
    ov = find_open(scan_, pos, "volume")
    rf = find_open(scan_, pos, "reference")
    o = 0; tag = ""
    if (ov > 0 && (rf == 0 || ov < rf)) { o = ov; tag = "volume" }
    else if (rf > 0)                    { o = rf; tag = "reference" }
    if (o == 0) { OUT[f] = OUT[f] substr(s, pos); break }

    gt = index(substr(scan_, o), ">")
    if (gt == 0) { OUT[f] = OUT[f] substr(s, pos); break }
    hpos = o + gt - 1
    atts = substr(scan_, o + length(tag) + 1, hpos - o - length(tag) - 1)

    if (substr(scan_, hpos - 1, 1) == "/") {   # self-closing: no body
      OUT[f] = OUT[f] substr(s, pos, hpos - pos)
      pos = hpos + 1
      continue
    }

    ce = index(substr(scan_, hpos + 1), "</" tag)
    if (ce == 0) { OUT[f] = OUT[f] substr(s, pos); break }
    cpos = hpos + ce
    cgt  = index(substr(scan_, cpos), ">")
    if (cgt == 0) { OUT[f] = OUT[f] substr(s, pos); break }
    cend = cpos + cgt - 1

    OUT[f] = OUT[f] substr(s, pos, o - pos)
    pos = cend + 1

    NB[f]++
    n = NB[f]
    TAG[f, n]  = tag
    OUR[f, n]  = is_our_block(tag, atts)
    BODY[f, n] = substr(s, hpos + 1, cpos - hpos - 1)
    if (tag == "reference") LABEL[f, n] = attr(atts, "name")
    else                    LABEL[f, n] = attr(atts, "stream") " / " attr(atts, "deviceCategory")
    parse_points(f, n, BODY[f, n])
  }
  NB1 = NB[1]; NB2 = NB[2]
  OUT1 = OUT[1]; OUT2 = OUT[2]

  # the loop above only knows one file at a time; mirror the per-index arrays
  # into the flat names END compares so the intent stays readable
  for (i = 1; i <= NB[f]; i++) {
    if (f == 1) {
      TAG1[i] = TAG[1, i]; OUR1[i] = OUR[1, i]; BODY1[i] = BODY[1, i]
      LABEL1[i] = LABEL[1, i]; NPT1[i] = NPT[1, i]; SKEL1[i] = SKEL[1, i]
      for (j = 1; j <= NPT[1, i]; j++) {
        IDX1[i, j] = IDX[1, i, j]; DB1[i, j] = DB[1, i, j]
      }
    } else {
      TAG2[i] = TAG[2, i]; OUR2[i] = OUR[2, i]; BODY2[i] = BODY[2, i]
      LABEL2[i] = LABEL[2, i]; NPT2[i] = NPT[2, i]; SKEL2[i] = SKEL[2, i]
      for (j = 1; j <= NPT[2, i]; j++) {
        IDX2[i, j] = IDX[2, i, j]; DB2[i, j] = DB[2, i, j]
      }
    }
  }
}

# ---------------------------------------------------------------------------
# parse_points: index + attenuation of every <point> in a block, plus the
# skeleton used for the "nothing else changed" comparison.
# ---------------------------------------------------------------------------
function parse_points(f, n, body,   rest, seg, idx, db, a, cpos, r2, w, dbstart, dblen) {
  NPT[f, n] = 0
  SKEL[f, n] = ""
  rest = body
  while (match(rest, /<point[ \t\r\n]*>[^<]*<\/point[ \t\r\n]*>/)) {
    seg  = substr(rest, RSTART, RLENGTH)
    SKEL[f, n] = SKEL[f, n] substr(rest, 1, RSTART - 1)
    rest = substr(rest, RSTART + RLENGTH)

    idx = seg
    sub(/^<point[ \t\r\n]*>/, "", idx)
    sub(/,.*$/, "", idx)
    sub(/[ \t\r\n]+$/, "", idx)

    # locate the attenuation token exactly the way patch_volume.awk does, so a
    # checker and a patcher can never disagree about which characters are "the
    # number"
    match(seg, /^<point[ \t\r\n]*>/)
    a = RLENGTH
    r2 = substr(seg, a + 1)
    cpos = index(r2, ",")
    if (cpos > 0) {
      r2 = substr(r2, cpos + 1)
      w = 0
      while (substr(r2, w + 1, 1) ~ /^[ \t\r\n]$/) w++
      dbstart = a + cpos + w + 1
      dblen = 0
      if (match(substr(seg, dbstart), /^[-+]?[0-9]+/)) dblen = RLENGTH
      db = substr(seg, dbstart, dblen)
      # whitespace-padded numbers are the whole point of the in-place trick:
      # right-trim before comparing / counting
      if (match(substr(seg, dbstart), /^[-+]?[0-9]+[ \t\r\n]*/))
        SKEL[f, n] = SKEL[f, n] substr(seg, 1, dbstart - 1) "@" \
                     substr(seg, dbstart + RLENGTH)
    } else {
      db = ""
      SKEL[f, n] = SKEL[f, n] seg
    }
    NPT[f, n]++
    IDX[f, n, NPT[f, n]] = idx
    DB[f, n, NPT[f, n]]  = db
  }
  SKEL[f, n] = SKEL[f, n] rest
}

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

function spaces(n) { if (n <= 0) return ""; return sprintf("%" n "s", "") }

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

function attr(atts, name,   re, v) {
  re = "(^|[ \t\r\n])" name "[ \t\r\n]*=[ \t\r\n]*\"[^\"]*\""
  if (match(atts, re)) {
    v = substr(atts, RSTART, RLENGTH)
    sub(/^[^"]*"/, "", v)
    sub(/"[ \t\r\n]*$/, "", v)
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

function is_our_block(tag, atts,   s, d, n) {
  if (tag == "volume") {
    s = attr(atts, "stream")
    d = attr(atts, "deviceCategory")
    if (s != "AUDIO_STREAM_MUSIC" && s != "1")      return 0
    if (d != "DEVICE_CATEGORY_SPEAKER" && d != "2") return 0
    return 1
  }
  if (tag == "reference") {
    n = attr(atts, "name")
    if (n ~ /^DEFAULT_DEVICE_CATEGORY_SPEAKER_VOLUME_CURVE/) return 1
    return 0
  }
  return 0
}
