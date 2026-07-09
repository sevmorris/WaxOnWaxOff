#!/bin/bash
# Meter-agreement gate: loudnorm measurement mode vs ebur128 peak=true.
# Usage: meter_agreement.sh file1 [file2 ...]
set -euo pipefail
# Bundled ffmpeg, resolved relative to this script (docs/dev/perf-2026-07/ → repo root).
FF="$(cd "$(dirname "$0")/../../.." && pwd)/WaxOnWaxOff/ffmpeg"

printf "%-28s %9s %9s %9s | %9s %9s %9s | %6s %6s\n" "file" "ln_I" "ln_TP" "ln_LRA" "eb_I" "eb_TP" "eb_LRA" "dI" "dTP"
for f in "$@"; do
  LN=$("$FF" -nostdin -hide_banner -nostats -y -i "$f" -map 0:a:0 \
      -af "loudnorm=I=-18:TP=-1.0:LRA=9:print_format=json" -f null - 2>&1 | python3 -c "
import sys,re,json
s=sys.stdin.read()
i=s.rfind('[Parsed_loudnorm')
m=re.search(r'\{[^{}]*\}', s[i:])
d=json.loads(m.group(0))
print(d['input_i'], d['input_tp'], d['input_lra'])")
  EB=$("$FF" -nostdin -hide_banner -nostats -y -i "$f" -map 0:a:0 \
      -af "ebur128=peak=true" -f null - 2>&1 | python3 -c "
import sys,re
s=sys.stdin.read()
tail=s[s.rfind('Summary:'):]
i=re.search(r'I:\s+(-?[\d.]+|-inf) LUFS', tail).group(1)
tp=re.search(r'Peak:\s+(-?[\d.]+|-inf) dBFS', tail).group(1)
lra=re.search(r'LRA:\s+(-?[\d.]+) LU', tail).group(1)
print(i, tp, lra)")
  python3 -c "
import sys
ln = '$LN'.split(); eb = '$EB'.split()
di = abs(float(ln[0]) - float(eb[0])); dtp = abs(float(ln[1]) - float(eb[1]))
flag = '' if (di <= 0.1 and dtp <= 0.1) else '  ** FAIL **'
print(f'%-28s %9s %9s %9s | %9s %9s %9s | {di:6.2f} {dtp:6.2f}{flag}' % ('$(basename "$f")', ln[0], ln[1], ln[2], eb[0], eb[1], eb[2]))"
done
