#!/usr/bin/env bash
#
# list-pod-ns-single.sh — namespace / isolation report for ONE pod.
#
# Companion to list-pod-ns.sh (which scans every running pod).  Drills into
# a single pod and answers "how isolated is this thing, really?".
#
# Usage:
#   ./list-pod-ns-single.sh <pod> [-n <namespace>]
#   ./list-pod-ns-single.sh <namespace>/<pod>
#
# Requires: kubectl, jq

set -uo pipefail

POD=""
NS=""

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--namespace) NS="${2:-}"
            [ -n "$NS" ] || { echo "Error: -n needs value" >&2; exit 2; }
            shift 2 ;;
        -h|--help)
            echo "Usage: $0 <pod> [-n <namespace>] | $0 <namespace>/<pod>"
            exit 0 ;;
        --) shift; break ;;
        -*) echo "Error: unknown option $1" >&2; exit 2 ;;
        *)
            if [ -z "$POD" ]; then POD="$1"; else
                echo "Error: unexpected arg $1" >&2; exit 2
            fi
            shift ;;
    esac
done

[ -n "$POD" ] || { echo "Usage: $0 <pod> [-n <namespace>] | $0 <namespace>/<pod>" >&2; exit 2; }

case "$POD" in
    */*) NS="${POD%%/*}"; POD="${POD##*/}" ;;
esac

if [ -z "$NS" ]; then
    NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
    [ -n "$NS" ] || NS="default"
fi

command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found" >&2; exit 1; }

PJSON=$(kubectl get pod "$POD" -n "$NS" -o json 2>/dev/null) || {
    echo "Error: cannot get pod $NS/$POD" >&2; exit 1; }

align() { if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi; }

# ---------------------------------------------------------------- A
echo "==============================================================="
echo "  Pod: $NS/$POD"
echo "==============================================================="
echo
echo "--- A. Pod-level namespace flags (spec, not per-container) ---"
echo

echo "$PJSON" | jq -r '
  def f($x; $d):
    ($x // $d) as $s
    | if $s == true then "true (SHARED)"
      elif $s == false then "false (ISOLATED)"
      else $s end;
  .spec as $s
  | "hostNetwork\t\(f($s.hostNetwork; false))",
    "hostPID    \t\(f($s.hostPID; false))",
    "hostIPC    \t\(f($s.hostIPC; false))",
    "hostUsers \t\(f($s.hostUsers; true))"
' | align

# ---------------------------------------------------------------- B
echo
echo "--- B. Per-container securityContext ---"
echo

{
    printf '%-20s %-6s %-7s %-7s %-9s %-9s %-10s %-20s %-10s\n' \
        "CONTAINER" "PRIV" "AEP" "RORFS" "RUNASUID" "NONROOT" "PROCMOUNT" "CAPS_ADD" "CAPS_DROP"
    echo "$PJSON" | jq -r '
      . as $p
      | (($p.spec.initContainers // []) + ($p.spec.containers // []) + ($p.spec.ephemeralContainers // []))[] as $c
      | ($c.securityContext // {}) as $s
      | [ $c.name,
          (($s.privileged // false) | tostring),
          (($s.allowPrivilegeEscalation // "unset") | tostring),
          (($s.readOnlyRootFilesystem // "unset") | tostring),
          (($s.runAsUser // "unset") | tostring),
          (($s.runAsNonRoot // "unset") | tostring),
          (($s.procMount // "Default") | tostring),
          ((($s.capabilities.add  // []) | join(",")) | if . == "" then "-" else . end),
          ((($s.capabilities.drop // []) | join(",")) | if . == "" then "-" else . end) ]
      | @tsv'
} | align

# ---------------------------------------------------------------- C
echo
echo "--- C. Mount propagation (mount-namespace axis) ---"
echo

{
    printf '%-22s %-20s %-18s %-24s %s\n' \
        "CONTAINER" "VOLUME" "PROPAGATION" "MOUNTPATH" "READONLY"
    echo "$PJSON" | jq -r '
      . as $p
      | ($p.spec.volumes // []) as $vols
      | (($p.spec.initContainers // []) + ($p.spec.containers // []) + ($p.spec.ephemeralContainers // []))[] as $c
      | ($c.volumeMounts // [])[] as $m
      | [ $c.name,
          $m.name,
          ($m.mountPropagation // "None"),
          $m.mountPath,
          (($m.readOnly // false) | tostring) ]
      | @tsv'
} | align

# ---------------------------------------------------------------- D
echo
echo "--- D. hostPath volumes ---"
echo

HP=$(echo "$PJSON" | jq -r '
  .spec.volumes // []
  | .[]
  | select(.hostPath != null)
  | [ .name, (.hostPath.path // "?"), (.hostPath.type // "unset") ]
  | @tsv
')

if [ -z "$HP" ]; then
    echo " (none)"
else
    {
        printf '%-22s %-34s %s\n' "VOLUME" "HOSTPATH" "TYPE"
        printf '%s\n' "$HP"
    } | align
fi

# ---------------------------------------------------------------- E
echo
echo "--- E. Verdict ---"
echo

FINDINGS=$(echo "$PJSON" | jq -r '
  def b($x; $d): if $x == null then $d else $x end;
  .spec as $s
  | ($p.spec.initContainers // []) + ($p.spec.containers // []) + ($p.spec.ephemeralContainers // [])) as $cs
  | [
      (if any($cs[]; (.securityContext.privileged // false)) then "HIGH\tprivileged container (all caps + host devices)" else empty end),
      (if b($s.hostPID; false) then "HIGH\thostPID -> /proc sees node processes (nsenter -t 1)" else empty end),
      (if b($s.hostNetwork; false) then "MEDIUM\thostNetwork (node interfaces/ports)" else empty end),
      (if b($s.hostIPC; false) then "MEDIUM\thostIPC (node shared memory / semaphores)" else empty end),
      (if b($s.hostUsers; true) then "INFO\thostUsers shared (no user-ns idmap; container root = host root UID)" else empty end),
      (if any(($s.volumes // [])[]; .hostPath != null) then "MEDIUM\thostPath volume(s) present — check paths" else empty end),
      (if any($cs[]; (((.securityContext.capabilities.add // []) | index("SYS_ADMIN")) != null))
       then "HIGH\tCAP_SYS_ADMIN (mount / nsenter / pivot_root)" else empty end),
      (if any($cs[]; (.securityContext.procMount // "Default") == "Unmasked")
       then "HIGH\tprocMount=Unmasked (default /proc masks removed)" else empty end),
      (if any($cs[]; ((.volumeMounts // [])[] | (.mountPropagation // "") == "Bidirectional"))
       then "HIGH\tmountPropagation=Bidirectional (mounts leak to host)" else empty end),
      (if any(($s.volumes // [])[]; (.hostPath.path // "") == "/")
       then "HIGH\thostPath / mounted (host root filesystem)" else empty end)
    ][]')

NCOUNT=$(printf '%s\n' "$FINDINGS" | grep -c "^" || true)
if [ -z "$FINDINGS" ]; then
    echo " (no findings — pod appears hardened)"
else
    printf '%s\n' "$FINDINGS" | align
    HIGH=$(printf '%s\n' "$FINDINGS" | grep -c "^HIGH" || true)
    MED=$(printf '%s\n' "$FINDINGS" | grep -c "^MEDIUM" || true)
    echo
    echo "HIGH findings: $HIGH   MEDIUM findings: $MED"
fi

echo
echo "Runtime verification (on node):"
echo "  kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[0].containerID}'"
echo "  # then on node:"
echo "  crictl inspect <cid> | jq -r .info.pid"
echo "  # then:"
echo "  for n in cgroup ipc mnt net pid user uts; do \\"
echo "    echo \"echo \"\$n host=\$(readlink /proc/1/ns/\$n) cont=\$(readlink /proc/\$CPID/ns/\$n)\"; done"
echo "  # same inode -> namespace SHARED with host"
echo "  # diff inode -> namespace ISOLATED"