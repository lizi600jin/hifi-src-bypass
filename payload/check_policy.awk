# =============================================================================
# check_policy.awk -- prove the patched audio policy is structurally identical
#                     to the factory one, apart from <profile> lines
# -----------------------------------------------------------------------------
#   awk -v MARKER=HIFI_SRC_BYPASS_UNIV -f check_policy.awk stock.xml patched.xml
#
#   exit 0 = the patch is safe to mount
#   exit 1 = structurally different -> the caller MUST refuse to mount
#
# This is the safety net that makes "run on any phone" acceptable.  The factory
# file is archived first, so if anything here fails we simply keep the factory
# policy mounted and the phone keeps making sound.
#
# The comparison is done on a *skeleton*: XML comments stripped (the vendor
# files hide a whole second copy of the profiles inside <!-- #ifdef ... -->),
# every <profile> element dropped, whitespace collapsed.  Those skeletons must
# match line for line.  Port and route inventories are compared separately, so
# "we only ever touched profile lines" is a machine-checked fact, not a claim.
# =============================================================================

BEGIN { NFILE = 0 }

FNR == 1 { NFILE++; FN = NFILE }

{
  # ---------------------------------------------------------------- read in
  if (FN == 1) { N1++; L1[N1] = $0 }
  else         { N2++; L2[N2] = $0 }
}

END {
  if (NFILE != 2) {
    printf("check_policy: need exactly 2 files (stock, patched), got %d\n", NFILE)
    exit 1
  }

  build(1)
  build(2)

  fail = 0

  # -------------------------------------------------- 1. skeleton equality
  if (S1N != S2N) {
    printf("FAIL skeleton: stock has %d structural line(s), patched has %d\n", S1N, S2N)
    fail = 1
    show_around()
  } else {
    bad = 0
    for (i = 1; i <= S1N; i++) {
      if (S1[i] != S2[i]) {
        if (bad < 5) {
          printf("FAIL skeleton line %d:\n", i)
          printf("     stock  : <%s>\n", S1[i])
          printf("     patched: <%s>\n", S2[i])
        }
        bad++
      }
    }
    if (bad > 0) { printf("FAIL skeleton: %d differing structural line(s)\n", bad); fail = 1 }
    else         { printf("ok   skeleton: %d structural line(s) identical\n", S1N) }
  }

  # ------------------------------------------- 2. port / route inventories
  for (k in P1) if (!(k in P2)) { printf("FAIL port removed: %s\n", k); fail = 1 }
  for (k in P2) if (!(k in P1)) { printf("FAIL port added  : %s\n", k); fail = 1 }
  for (k in R1) if (!(k in R2)) { printf("FAIL route removed: %s\n", k); fail = 1 }
  for (k in R2) if (!(k in R1)) { printf("FAIL route added  : %s\n", k); fail = 1 }
  np = 0; for (k in P1) np++
  nr = 0; for (k in R1) nr++
  if (!fail) printf("ok   inventory: %d port(s) and %d route(s) unchanged\n", np, nr)

  # ------------------------------------------------------ 3. routes as text
  if (RQ1 != RQ2) { printf("FAIL route block text changed\n"); fail = 1 }
  else            printf("ok   route lines: byte-identical (%d line(s))\n", RQN)

  # ------------------------------------------------------------- 4. marker
  if (index(HDR2, MARKER) > 0) printf("ok   marker: %s present\n", MARKER)
  else { printf("FAIL marker: %s not found in the patched file\n", MARKER); fail = 1 }
  if (index(HDR1, MARKER) > 0) { printf("FAIL stock file already carries %s\n", MARKER); fail = 1 }

  # ------------------------------------------------------- 5. profile shape
  # <profile> elements may be wrapped over several physical lines, so the
  # self-closing test belongs on the line that actually closes the element.
  pbad = 0
  inp = 0
  for (i = 1; i <= N2; i++) {
    if (CL2[i] ~ /^[ \t]*<profile[ \t>]/) inp = 1
    if (!inp) continue
    if (CL2[i] ~ /\/>/) {
      inp = 0
      if (CL2[i] !~ /\/>[ \t]*$/) { if (pbad < 3) printf("FAIL profile element not self-closed: %s\n", CL2[i]); pbad++ }
      if (nq(CL2[i]) % 2 != 0)    { if (pbad < 3) printf("FAIL odd quote count: %s\n", CL2[i]); pbad++ }
    }
  }
  if (inp) { printf("FAIL a <profile> element is never closed\n"); pbad++ }
  if (pbad > 0) fail = 1
  printf("ok   profile lines: %d live in stock, %d live in patched\n", PL1, PL2)
  if (PL2 < PL1) { printf("FAIL live profile count went down\n"); fail = 1 }

  # ------------------------------------------------------ 6. tail integrity
  if (T1 != T2) { printf("FAIL last structural line differs\n     stock  : %s\n     patched: %s\n", T1, T2); fail = 1 }
  else          printf("ok   tail: identical last line\n")

  if (fail) { printf("RESULT: REJECTED -- do not mount this file\n"); exit 1 }
  printf("RESULT: OK -- structure preserved, safe to mount\n")
  exit 0
}

# ============================================================ implementation
function nq(s,   c, n, i) { n = 0; for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == "\"") n++; return n }

function clive(ln,   pos, live, rest, p) {
  pos = 1; live = ""
  while (pos <= length(ln)) {
    if (INC) {
      rest = substr(ln, pos)
      p = index(rest, "-->")
      if (p == 0) pos = length(ln) + 1
      else { pos = pos + p + 2; INC = 0 }
    } else {
      rest = substr(ln, pos)
      p = index(rest, "<!--")
      if (p == 0) { live = live rest; pos = length(ln) + 1 }
      else { live = live substr(rest, 1, p - 1); pos = pos + p + 3; INC = 1 }
    }
  }
  return live
}

function norm(s,   t) {
  t = s
  gsub(/[ \t\r]+/, " ", t)
  sub(/^ /, "", t); sub(/ $/, "", t)
  return t
}

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

function build(f,   i, n, ln, live, t) {
  INC = 0
  sn = 0
  inprof = 0
  hdr = ""
  tail = ""
  rg = ""
  n = (f == 1) ? N1 : N2
  for (i = 1; i <= n; i++) {
    ln   = (f == 1) ? L1[i] : L2[i]
    live = clive(ln)
    if (f == 1) CL1[i] = live; else CL2[i] = live
    if (index(ln, MARKER) > 0) hdr = ln

    # ---- inventory + route harvesting, from live markup only --------------
    if (live ~ /^[ \t]*<mixPort[ \t>]/) {
      t = attr(live, "name")
      if (t != "") { if (f == 1) P1["mixPort:" t] = 1; else P2["mixPort:" t] = 1 }
    }
    if (live ~ /^[ \t]*<devicePort[ \t>]/) {
      t = attr(live, "tagName")
      if (t != "") { if (f == 1) P1["devicePort:" t] = 1; else P2["devicePort:" t] = 1 }
    }
    if (live ~ /<route[ \t]/) {
      t = norm(live)
      if (t != "") {
        if (f == 1) { R1[t] = 1; rg = rg "\n" t }
        else        { R2[t] = 1; rg = rg "\n" t }
      }
    }

    # ---- profile elements are dropped from the skeleton -------------------
    if (inprof) { if (live ~ /\/>/) inprof = 0; continue }
    if (live ~ /^[ \t]*<profile[ \t>]/) {
      if (f == 1) PL1++; else PL2++
      if (live !~ /\/>/) inprof = 1
      continue
    }

    t = norm(live)
    if (t == "") continue
    sn++
    if (f == 1) S1[sn] = t; else S2[sn] = t
    tail = t
  }
  if (f == 1) { S1N = sn; T1 = tail; HDR1 = hdr; RQ1 = rg; RQN = split(rg, dummy, "\n") - 1 }
  else        { S2N = sn; T2 = tail; HDR2 = hdr; RQ2 = rg }
}

function show_around(   i) {
  printf("     first stock structural lines:\n")
  for (i = 1; i <= (S1N < 6 ? S1N : 6); i++) printf("       %2d| %s\n", i, S1[i])
  printf("     first patched structural lines:\n")
  for (i = 1; i <= (S2N < 6 ? S2N : 6); i++) printf("       %2d| %s\n", i, S2[i])
}
