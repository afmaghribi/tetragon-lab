#!/usr/bin/env bash
#
# seccomp-compare.sh — run probe in every seccomp-lab pod and diff against
# a baseline pod.
#
# Usage: ./seccomp-compare.sh [namespace]   (default: seccomp-lab)
# Env:   OUT=/tmp/seccomp-lab              (raw output directory)

set -uo pipefail

NS="${1:-seccomp-lab}"
OUT="${OUT:-/tmp/seccomp-lab}"
BASE="${BASE:-seccomp-baseline}"

mkdir -p "$OUT"

command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl not found" >&2; exit 1; }

mapfile -t PODS < <(kubectl get pods -n "$NS" -o name | sed 's|pod/||' | sort)

if [ "${#PODS[@]}" -eq 0 ]; then
    echo "Error: no pods in namespace $NS" >&2
    exit 1
fi

echo "collecting probe output -> $OUT"
for p in "${PODS[@]}"; do
    if kubectl exec -n "$NS" "$p" -- python3 /probe/probe-simple.py >"$OUT/$p.tsv" 2>"$OUT/$p.err"; then
        printf '  ok   %s\n' "$p"
    else
        printf '  FAIL %s (see %s/%s.err)\n' "$p" "$OUT" "$p"
        kubectl get pod -n "$NS" "$p" \
          -o jsonpath='  phase={.status.phase} reason={.status.containerStatuses[0].state.waiting.reason}{"\n"}' 2>/dev/null
    fi
done

echo
echo "=== headers (Seccomp / NoNewPrivs / CapEff) ==="
for p in "${PODS[@]}"; do
    printf '%-26s %s\n' "$p" "$(grep -E '^# (Seccomp |NoNewPrivs|CapEff)' "$OUT/$p.tsv" 2>/dev/null | paste -sd ' ' -)"
done

echo
echo "=== diff against baseline ($BASE) ==="
if [ ! -f "$OUT/$BASE.tsv" ]; then
    echo "baseline pod '$BASE' not found; skipping diff"
else
    for p in "${PODS[@]}"; do
        [ "$p" = "$BASE" ] && continue
        echo
        echo "--- $p ---"
        diff <(grep -v '^#' "$OUT/$BASE.tsv" | awk -F' +' '{print $1"\t"$2}' | sort) \
             <(grep -v '^#' "$OUT/$p.tsv"      | awk -F' +' '{print $1"\t"$2}' | sort) \
        || true
    done
fi