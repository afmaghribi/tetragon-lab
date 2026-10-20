#!/usr/bin/env bash
#
# list-pod-ns.sh — list all RUNNING pods namespace configuration
#
# Usage:
#   ./list-pod-ns.sh                 # all namespaces
#   ./list-pod-ns.sh <k8s-ns>        # single Kubernetes namespace
#
# Section A: per-pod host-namespace flags (hostNetwork/hostPID/hostIPC/hostUsers)
# Section B: distinct Kubernetes namespaces that contain running pods
#
# Each flag shows two values: raw spec value + SHARED/ISOLATED label.
#   true (SHARED)    = pod joins HOST namespace
#   false (ISOLATED) = pod has its OWN namespace
#
# Requires: kubectl (jq optional; falls back to custom-columns)

set -uo pipefail

NS="${1:-}"

if [ -n "$NS" ]; then
    SCOPE=(-n "$NS")
    SCOPE_LABEL="namespace=$NS"
else
    SCOPE=(--all-namespaces)
    SCOPE_LABEL="all namespaces"
fi

fmt() {
    case "$1" in
        true)  printf 'true (SHARED)'   ;;
        false) printf 'false (ISOLATED)' ;;
        *)    printf '%-16s' "$1"       ;;
    esac
}

echo "==================================================="
echo " Running pods — $SCOPE_LABEL"
echo "==================================================="
echo
echo "Flags (pod-level, not per-container):"
echo "  HNET=network  HPID=PID  HIPC=IPC  HUSERS=user namespace"
echo "  true (SHARED)    = uses HOST namespace"
echo "  false (ISOLATED) = has its OWN namespace"
echo "  NOTE: HUSERS defaults true (SHARED) when unset in manifest."
echo

if command -v jq >/dev/null 2>&1; then
    # ---------- Section A: per-pod host-namespace flags ----------
    printf '%-26s %-42s %-17s %-17s %-17s %-17s\n' \
        "K8S-NAMESPACE" "POD" "HNET" "HPID" "HIPC" "HUSERS"
    printf '%-26s %-42s %-17s %-17s %-17s %-17s\n' \
        "--------------------------" "------------------------------------------" \
        "-----------------" "-----------------" "-----------------" "-----------------"

    kubectl get pods "${SCOPE[@]}" --field-selector=status.phase=Running -o json \
    | jq -r '
        def d($x; $def):
          if $x == null then $def else ($x | tostring) end;
        .items[]
        | .spec as $s
        | [
            .metadata.namespace,
            .metadata.name,
            d($s.hostNetwork; false),
            d($s.hostPID; false),
            d($s.hostIPC; false),
            d($s.hostUsers; true)
          ]
        | @tsv
      ' \
    | while IFS=$'\t' read -r ns pod hnet hpid hipc husers; do
        printf '%-26s %-42s %-17s %-17s %-17s %-17s\n' \
          "$ns" "$pod" "$(fmt "$hnet")" "$(fmt "$hpid")" "$(fmt "$hipc")" "$(fmt "$husers")"
      done

    # ---------- Section B: distinct K8s namespaces with running pods ----------
    echo
    echo "--- Kubernetes namespaces with running pods ---"
    kubectl get pods "${SCOPE[@]}" --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' \
    | sort | uniq -c | sort -rn
else
    echo "(no jq — showing raw spec values; true=SHARED, false=ISOLATED)"
    echo
    kubectl get pods "${SCOPE[@]}" --field-selector=status.phase=Running \
      -o custom-columns='K8S-NAMESPACE:.metadata.namespace,POD:.metadata.name,HNET:.spec.hostNetwork,HPID:.spec.hostPID,HIPC:.spec.hostIPC,HUSERS:.spec.hostUsers'
fi