#!/usr/bin/env bash
#
# list-pod-caps.sh — one-line-per-container capability inventory.
#
# Usage:
#   ./list-pod-caps.sh                 # all namespaces
#   ./list-pod-caps.sh kube-system     # one namespace
#
# Columns: NAMESPACE PODNAME PRIV AEP RUNAS CAPS_ADD CAPS_DROP
#   PODNAME = container name (init containers first, then app containers)
#
# Requires: kubectl, jq

set -uo pipefail

NS="${1:-}"
if [ "$NS" = "-h" ] || [ "$NS" = "--help" ]; then
    sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

if [ -n "$NS" ]; then SCOPE=(-n "$NS"); else SCOPE=(--all-namespaces); fi

command -v kubectl >/dev/null 2>&1 || { echo "error: kubectl not found" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 1; }

kubectl get pods "${SCOPE[@]}" -o json \
| jq -r '
  def caps($x):
    if $x == null then "-"
    elif ($x | length) == 0 then "-"
    else ($x | join(",")) end;

  ["NAMESPACE","PODNAME","PRIV","AEP","RUNAS","CAPS_ADD","CAPS_DROP"],
  ( .items[]
    | . as $p
    | (((.spec.initContainers // []) | map(. + {_k: 0}))
       + ((.spec.containers    // []) | map(. + {_k: 1})))[] as $c
    | ($c.securityContext // {}) as $s
    | [ $p.metadata.namespace,
        $c.name,
        (($s.privileged // false) | tostring),
        (($s.allowPrivilegeEscalation // "unset") | tostring),
        (($s.runAsUser // $p.spec.securityContext.runAsUser // "unset") | tostring),
        caps($s.capabilities.add),
        caps($s.capabilities.drop)
      ] )
  | @tsv' \
| if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi