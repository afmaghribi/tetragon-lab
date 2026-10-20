#!/usr/bin/env bash
#
# gen-possible-ns.sh — emit every valid host-namespace combination
#
# 16 raw combinations exist (hostNetwork x hostPID x hostIPC x hostUsers).
# hostUsers=false forbids any other host ns being shared (admission rejects),
# so 9 are valid: 1 with userns-only-isolated + 8 with userns shared.
#
# Usage: ./gen-possible-ns.sh [namespace]
# Default namespace: possible-ns

set -euo pipefail

NS="${1:-possible-ns}"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

out="possible-ns.generated.yaml"
: > "$out"

for n in 0 1; do
for p in 0 1; do
for i in 0 1; do
for u in 0 1; do
    # hostUsers=false forbids any other host namespace -> skip invalid
    if [ "$u" = 0 ] && { [ "$n" = 1 ] || [ "$p" = 1 ] || [ "$i" = 1 ]; }; then
        echo "skip (invalid): net=$n pid=$p ipc=$i userns=$u"
        continue
    fi
    name="pod-${n}${p}${i}"
    [ "$u" = 0 ] && name="${name}-userns"
    {
        echo "---"
        echo "apiVersion: v1"
        echo "kind: Pod"
        echo "metadata:"
        echo "  name: $name"
        echo "  namespace: $NS"
        echo "spec:"
        [ "$n" = 1 ] && echo "  hostNetwork: true" && echo "  dnsPolicy: ClusterFirstWithHostNet"
        [ "$p" = 1 ] && echo "  hostPID: true"
        [ "$i" = 1 ] && echo "  hostIPC: true"
        [ "$u" = 0 ] && echo "  hostUsers: false"
        echo "  containers:"
        echo "  - name: c"
        echo "    image: ubuntu:22.04"
        echo "    command: [\"/bin/bash\", \"-c\", \"sleep 13337\"]"
    } >> "$out"
done; done; done; done

echo
echo "Generated $(grep -c '^---' "$out") pods -> $out"
kubectl apply -f "$out"
echo
echo "Verify:"
echo "  ./list-pod-ns.sh $NS"