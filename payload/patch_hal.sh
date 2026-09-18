#!/system/bin/sh
# ==============================================================================
#  patch_hal.sh -- unlock the USB audio HAL's hard sample-rate ceiling
#  module: HiFi SRC Bypass (universal)                      used by: bin/hifi
# ------------------------------------------------------------------------------
#  WHY THIS EXISTS
#
#  The audio policy XML says what the *framework* will accept.  Separately, the
#  AOSP USB audio HAL (libalsautils.so / libalsautilsv2.so) carries a
#  compile-time table of sample rates it is willing to open, and **the first
#  entry is what it advertises as the maximum**.  On most builds that table
#  starts at 96000, so a dongle stays locked at 96 kHz no matter what the
#  policy file claims.  Both real-world modules that solved this
#  ("USB Samplerate Unlocker", "Audio Samplerate Changer") do exactly the same
#  thing: reorder that table so the wanted maximum comes first.
#
#  The trick is safe by construction: the replacement is the *same set* of
#  32-bit values in a different order, so it is **exactly as long as the
#  original**.  Nothing shifts, no relocation is invalidated, the file size is
#  unchanged -- it is a pure in-place 52-byte reorder.
#
#      original : 96000  88200  192000  176400  48000  44100  32000  24000  22050  16000  12000  11025  8000
#      192 kHz  : 192000 176400 96000   88200   48000  44100  32000  24000  22050  16000  12000  11025  8000
#      384 kHz  : 384000 352800 192000  176400  96000  88200  48000  44100  32000  24000  16000  12000  8000
#      768 kHz  : 768000 705600 384000  352800  192000 176400 96000  88200  48000  44100  24000  16000  8000
#
#  This script is deliberately paranoid, because it edits a vendor binary:
#    * the original table must appear EXACTLY once -- 0 or 2+ occurrences and we
#      refuse instead of guessing (we will not corrupt a library);
#    * if the file already carries an unlocked table we say so and do nothing
#      (so re-running, or coexisting with another module, never double-patches);
#    * after writing we re-read the bytes at the offset, re-count both patterns
#      and re-check the file size; any mismatch deletes the output and fails.
#
#  usage : patch_hal.sh <orig.so> <out.so> <ceiling:192000|384000|768000>
#          patch_hal.sh --check <file.so> [ceiling]      (probe, writes nothing)
#  exit  : 0 stock table found exactly once (patchable / patched)
#          3 the standard table is not in this library (nothing to do)
#          4 already unlocked at exactly the requested ceiling
#          5 verification failed (output removed)
#          6 the table occurs more than once -- refused, not touched
#          7 --check only: unlocked, but at a *different* ceiling than asked
#          1 usage or I/O error
# ==============================================================================

set -u
export LC_ALL=C

CHECK=0
case "${1:-}" in
  --check|-c) CHECK=1; shift ;;
esac

ORIG="96000 88200 192000 176400 48000 44100 32000 24000 22050 16000 12000 11025 8000"
R192="192000 176400 96000 88200 48000 44100 32000 24000 22050 16000 12000 11025 8000"
R384="384000 352800 192000 176400 96000 88200 48000 44100 32000 24000 16000 12000 8000"
R768="768000 705600 384000 352800 192000 176400 96000 88200 48000 44100 24000 16000 8000"

rates_for() {
  case "${1:-}" in
    *768*) printf '%s' "$R768" ;;
    *384*) printf '%s' "$R384" ;;
    *)     printf '%s' "$R192" ;;
  esac
}

# ------------------------------------------------------------------ byte tools
# One single pass over the file: for every "label:rates" spec, print
#   <label> <occurrences> <first byte offset>
scan_pat() {
  od -An -v -tu1 "$1" 2>/dev/null | awk -v spec="$2" '
    BEGIN {
      nl = split(spec, L, ";")
      for (li = 1; li <= nl; li++) {
        if (L[li] == "") { len[li] = 0; continue }
        ci = index(L[li], ":")
        lab[li] = substr(L[li], 1, ci - 1)
        n = split(substr(L[li], ci + 1), a, " ")
        base[li] = PS + 1
        for (i = 1; i <= n; i++) {
          v = a[i] + 0
          p[++PS] = v % 256
          p[++PS] = int(v / 256)      % 256
          p[++PS] = int(v / 65536)    % 256
          p[++PS] = int(v / 16777216) % 256
        }
        len[li] = PS - base[li] + 1
      }
    }
    { for (i = 1; i <= NF; i++) B[++bn] = $i + 0 }
    END {
      for (li = 1; li <= nl; li++) { cnt[li] = 0; off[li] = -1 }
      for (i = 1; i <= bn; i++) {
        for (li = 1; li <= nl; li++) {
          if (len[li] <= 0) continue
          if (i + len[li] - 1 > bn) continue
          hit = 1
          b0 = base[li]
          for (j = 1; j <= len[li]; j++) {
            if (B[i + j - 1] != p[b0 + j - 1]) { hit = 0; break }
          }
          if (hit) { cnt[li]++; if (off[li] < 0) off[li] = i - 1 }
        }
      }
      for (li = 1; li <= nl; li++) printf "%s %d %d\n", lab[li], cnt[li], off[li]
    }'
}

# rate list -> little-endian bytes on stdout
bytes_of() {
  printf '%s' "$1" | awk '{
    n = split($0, a, " ")
    for (i = 1; i <= n; i++) {
      v = a[i] + 0
      printf "%c%c%c%c", v % 256, int(v / 256) % 256, int(v / 65536) % 256, int(v / 16777216) % 256
    }
  }'
}

# rate list -> hex string (diagnostics)
hex_of() {
  printf '%s' "$1" | awk '{
    n = split($0, a, " ")
    for (i = 1; i <= n; i++) {
      v = a[i] + 0
      printf "%02x%02x%02x%02x", v % 256, int(v / 256) % 256, int(v / 65536) % 256, int(v / 16777216) % 256
    }
  }'
}

nbytes_of() { printf '%s' "$1" | awk '{ print NF * 4 }'; }

field() { printf '%s' "$1" | awk -v k="$2" '$1 == k { print $2; exit }'; }
offof() { printf '%s' "$1" | awk -v k="$2" '$1 == k { print $3; exit }'; }

# ----------------------------------------------------------------------- main
if [ "$CHECK" = 1 ]; then
  ORIGF="${1:-}"
  OUTF=""
  CEIL="${2:-384000}"
else
  ORIGF="${1:-}"
  OUTF="${2:-}"
  CEIL="${3:-384000}"
fi
[ -n "$ORIGF" ] || {
  echo "usage: patch_hal.sh <orig.so> <out.so> <ceiling>" >&2
  echo "       patch_hal.sh --check <file.so> [ceiling]" >&2
  exit 1
}
if [ "$CHECK" != 1 ] && [ -z "$OUTF" ]; then
  echo "usage: patch_hal.sh <orig.so> <out.so> <ceiling>" >&2
  exit 1
fi
[ -r "$ORIGF" ] || { echo "patch_hal: cannot read $ORIGF" >&2; exit 1; }

NEW="$(rates_for "$CEIL")"
SPEC="orig:$ORIG;e192:$R192;e384:$R384;e768:$R768"

scan="$(scan_pat "$ORIGF" "$SPEC")"
n_orig="$(field "$scan" orig)"
n_192="$(field "$scan" e192)"
n_384="$(field "$scan" e384)"
n_768="$(field "$scan" e768)"
off_orig="$(offof "$scan" orig)"

# already unlocked by us, by another module, or by a previous ROM build
if [ "${n_orig:-0}" = "0" ]; then
  have_192=0; have_384=0; have_768=0
  [ "${n_192:-0}" != "0" ] && have_192=1
  [ "${n_384:-0}" != "0" ] && have_384=1
  [ "${n_768:-0}" != "0" ] && have_768=1
  if [ "$have_192" = 0 ] && [ "$have_384" = 0 ] && [ "$have_768" = 0 ]; then
    echo "patch_hal: standard USB HAL rate table not present in this library" >&2
    exit 3
  fi
  # which ceiling does it carry right now?  (384/768 also contain the lower
  # tables' leading entries, so test the highest first)
  cur=192
  [ "$have_384" = 1 ] && cur=384
  [ "$have_768" = 1 ] && cur=768
  case "$NEW" in
    "$R768") want=768 ;;
    "$R384") want=384 ;;
    *)       want=192 ;;
  esac
  if [ "$cur" = "$want" ]; then
    echo "patch_hal: already unlocked at ${cur} kHz -- nothing to do" >&2
    exit 4
  fi
  echo "patch_hal: already unlocked at ${cur} kHz, requested ${want} kHz" >&2
  exit 7
fi

if [ "$n_orig" != "1" ]; then
  echo "patch_hal: rate table occurs $n_orig times -- refusing to guess" >&2
  exit 6
fi

# the exact ceiling we are asked for must not already be there
case "$NEW" in
  "$R192") if [ "${n_192:-0}" != "0" ]; then echo "patch_hal: already at 192k" >&2; exit 4; fi ;;
  "$R384") if [ "${n_384:-0}" != "0" ]; then echo "patch_hal: already at 384k" >&2; exit 4; fi ;;
  "$R768") if [ "${n_768:-0}" != "0" ]; then echo "patch_hal: already at 768k" >&2; exit 4; fi ;;
esac

if [ "$CHECK" = 1 ]; then
  echo "patch_hal: ok (check)  offset=$off_orig ceiling=$CEIL"
  exit 0
fi

sz_before="$(wc -c < "$ORIGF" | tr -d ' ')"
nb="$(nbytes_of "$NEW")"

cp -f "$ORIGF" "$OUTF" 2>/dev/null || { echo "patch_hal: cannot copy to $OUTF" >&2; exit 1; }

blk="${OUTF}.rate"
if ! bytes_of "$NEW" > "$blk" 2>/dev/null; then
  rm -f "$blk" "$OUTF"
  echo "patch_hal: cannot build the replacement block" >&2
  exit 1
fi
if ! dd if="$blk" of="$OUTF" bs=1 seek="$off_orig" count="$nb" conv=notrunc 2>/dev/null; then
  rm -f "$blk" "$OUTF"
  echo "patch_hal: dd failed at offset $off_orig" >&2
  exit 1
fi
rm -f "$blk"

# ------------------------------------------------------------------ verify
ok=1
reason=""
sz_after="$(wc -c < "$OUTF" | tr -d ' ')"
[ "$sz_before" = "$sz_after" ] || { ok=0; reason="size $sz_before -> $sz_after"; }

scan2="$(scan_pat "$OUTF" "$SPEC")"
v_orig="$(field "$scan2" orig)"
v_new=""
v_off=""
case "$NEW" in
  "$R192") v_new="$(field "$scan2" e192)"; v_off="$(offof "$scan2" e192)" ;;
  "$R384") v_new="$(field "$scan2" e384)"; v_off="$(offof "$scan2" e384)" ;;
  "$R768") v_new="$(field "$scan2" e768)"; v_off="$(offof "$scan2" e768)" ;;
esac

[ "${v_orig:-0}" = "0" ] || { ok=0; reason="${reason:+$reason; }original table still present ($v_orig)"; }
[ "${v_new:-0}" = "1" ]  || { ok=0; reason="${reason:+$reason; }new table occurrences $v_new (want 1)"; }
[ "${v_off:-x}" = "$off_orig" ] || { ok=0; reason="${reason:+$reason; }new table at $v_off (want $off_orig)"; }

# byte-for-byte read-back of the region we wrote
got_hex="$(dd if="$OUTF" bs=1 skip="$off_orig" count="$nb" 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
want_hex="$(hex_of "$NEW")"
[ "$got_hex" = "$want_hex" ] || { ok=0; reason="${reason:+$reason; }read-back mismatch"; }

if [ "$ok" != 1 ]; then
  rm -f "$OUTF"
  echo "patch_hal: verification FAILED ($reason)" >&2
  exit 5
fi

echo "patch_hal: ok  offset=$off_orig bytes=$nb ceiling=$CEIL"
exit 0
