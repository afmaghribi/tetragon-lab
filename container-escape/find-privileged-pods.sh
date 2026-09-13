#!/bin/bash
# find-privileged-pods.sh — inventory pods whose securityContext makes
# container escapes reachable. Mirrors the "find attackable pods" step of
# kube-hunter / polaris, as a one-liner.
#
# Output columns (TSV):
#   NAMESPACE  POD  privileged  hostPID  hostNetwork
#
# Usage:
#   ./find-privileged-pods.sh                  # all namespaces
#   ./find-privileged-pods.sh kube-system      # one namespace
#   PRIV_ONLY=1 ./find-privileged-pods.sh      # only truly privileged
set -u

NS="${1:+-n $1}"
PRIV_ONLY="${PRIV_ONLY:-0}"

kubectl get pods $NS -o json | jq -r --argjson priv "$PRIV_ONLY" '
  .items[]
  | . as $pod
  | .spec.containers[]
  | {
      namespace: $pod.metadata.namespace,
      pod:       $pod.metadata.name,
      priv:      (.securityContext.privileged // false),
      hostPid:   ($pod.spec.hostPID // false),
      hostNet:   ($pod.spec.hostNetwork // false)
    }
  | select(.priv == true or (.hostPid == true) or (.hostNet == true))
  | select(.priv == true or ($priv != 1))
  | [.namespace, .pod, .priv, .hostPid, .hostNet]
  | @tsv
' | column -t -s $'\t'

echo
echo "legend: privileged | hostPID | hostNetwork  (true = attackable surface)"
echo "spot-check: pod 2x:  kubectl get pod -o yaml | grep -A2 securityContext"