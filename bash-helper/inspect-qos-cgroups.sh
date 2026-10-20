#!/usr/bin/env bash
#
# inspect-qos-cgroups.sh — QoS class + cgroup resource settings for pods.
#
# Usage:
#   ./inspect-qos-cgroups.sh list [-n NS]            # declared QoS + resources
#   ./inspect-qos-cgroups.sh show <pod> [-n NS]      # one pod: QoS, cgroup path, cmds
#   ./inspect-qos-cgroups.sh runtime <pod> [-n NS]  # read /sys/fs/cgroup inside
#
# Requires: kubectl, jq

set -uo pipefail

usage() {
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-2}"
}

CMD="${1:-list}"; shift || true
[ "$CMD" = "-h" ] || [ "$CMD" = "--help" ] && usage 0

NS=""; POD=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--namespace) NS="${2:-}"
            [ -n "$NS" ] || { echo "Error: -n needs value" >&2; exit 2; }
            shift 2 ;;
        -*) echo "Error: unknown option $1" >&2; usage ;;
        *) POD="$1"; shift ;;
    esac
done

command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found" >&2; exit 1; }
if command -v column >/dev/null 2>&1; then align() { column -t -s $'\t'; }
else align() { cat; } fi

# scope args
if [ -n "$NS" ]; then SCOPE=(-n "$NS"); SCOPE_LABEL="namespace=$NS"
else SCOPE=(--all-namespaces); SCOPE_LABEL="all namespaces"; fi

case "$CMD" in
# ------------------------------------------------------------------ list
list)
    PODS=$(kubectl get pods "${SCOPE[@]}" -o json)

    echo "==========================================================="
    echo " QoS classes — $SCOPE_LABEL"
    echo "==========================================================="
    echo

    {
        printf '%s\n' "NAMESPACE POD QOS CPU_REQ CPU_LIM MEM_REQ MEM_LIM"
        echo "$PODS" | jq -r '
          .items[] as $p
          | (($p.spec.initContainers // []) + ($p.spec.containers // []))[] as $c
          | ($c.resources // {}) as $r
          | ($p.status.qosClass // "?") as $q
          | [ $p.metadata.namespace, $p.metadata.name, $q,
              ($r.requests.cpu // "-"),
              ($r.limits.cpu   // "-"),
              ($r.requests.memory // "-"),
              ($r.limits.memory   // "-") ]
          | @tsv'
    } | align

    echo
    echo "--- QoS counts ---"
    echo "$PODS" | jq -r '.items[] | (.status.qosClass // "Unknown")' \
    | sort | uniq -c | sort -rn
    ;;
# ------------------------------------------------------------------ show
show)
    [ -n "$POD" ] || usage
    [ -n "$NS" ] || NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
    [ -n "$NS" ] || NS=default

    PJ=$(kubectl get pod "$POD" -n "$NS" -o json 2>/dev/null) || {
        echo "Error: pod $NS/$POD not found" >&2; exit 1; }
    UID_=$(echo "$PJ" | jq -r '.metadata.uid')
    QOS=$(echo "$PJ" | jq -r '.status.qosClass // "-"')
    QOS_LC=$(echo "$QOS" | tr '[:upper:]' '[:lower:]')
    NODE=$(echo "$PJ" | jq -r '.spec.nodeName // "?"')
    UID_US=$(echo "$UID_" | tr '-' '_')
    SLICE="kubepods-${QOS_LC}-pod${UID_US}.slice"

    echo "==========================================================="
    echo " $NS/$POD  QoS=$QOS  node=$NODE"
    echo "==========================================================="
    echo
    echo "cgroup path (systemd / cgroup v2):"
    echo "  /sys/fs/cgroup/kubepods.slice/kubepods-${QOS_LC}.slice/${SLICE}"
    echo
    echo "cgroup path (cgroupfs / cgroup v1):"
    echo "  /sys/fs/cgroup/kubepods/${QOS_LC}/pod${UID_}"
    echo
    echo "per-container:"
    echo
    {
        printf '%s\n' "CONTAINER KIND CPU_REQ CPU_LIM MEM_REQ MEM_LIM"
        echo "$PJ" | jq -r '
          .spec as $s
          | (($s.initContainers // []) | map(. + {_k:"init"}))
            + (($s.containers    // []) | map(. + {_k:"app"})) )[] as $c
          | ($c.resources // {}) as $r
          | [ $c.name, $c._k,
              ($r.requests.cpu // "-"),
              ($r.limits.cpu   // "-"),
              ($r.requests.memory // "-"),
              ($r.limits.memory   // "-") ]
          | @tsv'
    } | align

    echo
    echo "systemctl show $SLICE -p ControlGroup -p CPUWeight -p CPUQuotaPerSecUSec \\"
    echo "  -p MemoryMax -p MemoryHigh -p MemorySwapMax -p TasksMax"
    ;;
# ------------------------------------------------------------------ runtime
runtime)
    [ -n "$POD" ] || usage
    [ -n "$NS" ] || NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
    [ -n "$NS" ] || NS=default

    PJ=$(kubectl get pod "$POD" -n "$NS" -o json 2>/dev/null) || {
        echo "Error: pod $NS/$POD not found" >&2; exit 1; }

    QOS=$(echo "$PJ" | jq -r '.status.qosClass // "?"' | tr '[:upper:]' '[:lower:]')
    UID_=$(echo "$PJ" | jq -r '.metadata.uid')
    UID_US=$(echo "$UID_" | tr '-' '_')
    SLICE="kubepods-${QOS}-pod${UID_US}.slice"

    echo "=== pod slice ==="
    kubectl exec "$POD" -n "$NS" -- cat /proc/self/cgroup
    echo
    echo "=== cgroup v2 (unified) ==="
    for f in cgroup.type cpu.weight cpu.max cpu.weight.nice \
             memory.current memory.max memory.high memory.low memory.min \
             memory.swap.current memory.swap.max \
             pids.current pids.max cpuset.cpus.effective io.weight; do
        kubectl exec "$POD" -n "$NS" -- cat "/sys/fs/cgroup/$f" 2>/dev/null \
          | while read -r val; do printf '%-24s = %s\n' "$f" "$val"; done
    done
    ;;
*) usage ;;
esac