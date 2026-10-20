#!/usr/bin/env bash
#
# cgroup-pod.sh — resolve pod's systemd cgroup slice and print its
# configured values.  Sections A and B only.
#
# A. pod -> node / uid / qos / slice / cgroup path
# B. systemd configured values (systemctl show)
#
# Usage:
#   ./cgroup-pod.sh <pod> [-n <namespace>]
#   ./cgroup-pod.sh <namespace>/<pod>
#
# Default namespace: "default"
#
# Run ON node hosting pod (reads /sys/fs/cgroup, talks to systemd).
# kubectl is only used to resolve UID / QoS / nodeName.

set -uo pipefail

usage() {
    cat <<'EOF'
cgroup-pod.sh — show pod's systemd cgroup slice and configured values

Usage:
  ./cgroup-pod.sh <pod> [-n <namespace>]
  ./cgroup-pod.sh <namespace>/<pod>

Options:
  -n, --namespace NS   Kubernetes namespace (default: "default")
  -h, --help           this help

Examples:
  ./cgroup-pod.sh cilium-h9cpt -n kube-system
  ./cgroup-pod.sh kube-system/cilium-h9cpt
  ./cgroup-pod.sh pod-most-priv -n most-least-ns
EOF
    exit "${1:-2}"
}

POD=""
NS=""

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--namespace) NS="${2:-}"
            [ -n "$NS" ] || { echo "error: -n needs value" >&2; exit 2; }
            shift 2 ;;
        -h|--help) usage 0 ;;
        --) shift; break ;;
        -*) echo "error: unknown option $1" >&2; usage ;;
        *)
            [ -z "$POD" ] || { echo "error: unexpected arg: $1" >&2; usage; }
            POD="$1"; shift ;;
    esac
done

[ -n "$POD" ] || usage

# Accept "<namespace>/<pod>" form.
case "$POD" in
    */*)
        [ -n "$NS" ] && { echo "error: namespace given twice" >&2; exit 2; }
        NS="${POD%%/*}"
        POD="${POD##*/}"
        ;;
esac

if [ -z "$NS" ]; then
    NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
    [ -n "$NS" ] || NS="default"
fi

command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found" >&2; exit 1; }

UID_=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.metadata.uid}')
QOS=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.qosClass}')
NODE=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}')
MIRROR=$(kubectl get pod "$POD" -n "$NS" \
  -o jsonpath='{.metadata.annotations.kubernetes\.io/config\.mirror}' 2>/dev/null)

if [ -z "$QOS" ]; then
    echo "pod $NS/$POD has no QoS class yet" >&2
    echo "no cgroup exists until pod is scheduled and runtime starts it" >&2
    exit 1
fi

QOS_LC=$(printf '%s' "$QOS" | tr 'A-Z' 'a-z')
UID_US=${UID_//-/_}
SLICE="kubepods-${QOS_LC}-pod${UID_US}.slice"

if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    CGV="v2"
    CGROOT="/sys/fs/cgroup/kubepods.slice/kubepods-${QOS_LC}.slice/${SLICE}"
else
    CGV="v1"
    CGROOT="/sys/fs/cgroup/kubepods/${QOS_LC}/pod${UID_}"
fi

# ------------------------------------------------------------------ A
echo "==============================================================="
echo " A. Pod -> cgroup mapping"
echo "==============================================================="
printf '%-10s %s\n' \
  "pod"   "$NS/$POD" \
  "node"  "$NODE" \
  "qos"   "$QOS" \
  "uid"   "$UID_" \
  "slice" "$SLICE" \
  "cgroup" "$CGV" \
  "path"  "$CGROOT"

if [ -n "$MIRROR" ]; then
    printf '%-10s %s\n' \
      "static" "yes (mirror pod; may live under system.slice/kube-*-$NODE.service)"
fi

if [ -d "$CGROOT" ]; then
    printf '%-10s %s\n' "exists" "yes"
else
    printf '%-10s %s\n' "exists" "NO -- are you on $NODE?"
fi

# ------------------------------------------------------------------ B
echo
echo "==============================================================="
echo " B. systemd configured values (systemctl show)"
echo "==============================================================="

if ! systemctl show "$SLICE" -p ControlGroup --value 2>/dev/null | grep -q .; then
    echo "no systemd unit named $SLICE"
    echo "(driver is cgroupfs, this is a static/mirror pod, or wrong node)"
    if [ -d "$CGROOT" ]; then
        echo
        echo "raw cgroup files instead:"
        for f in cpu.weight cpu.max memory.max memory.high memory.swap.max pids.max; do
            [ -e "$CGROOT/$f" ] && printf '  %-24s = %s\n' "$f" "$(cat "$CGROOT/$f" 2>/dev/null)"
        done
    fi
    exit 0
fi

(
    printf '%s\n' "Property Value"
    systemctl show "$SLICE" \
      -p ControlGroup -p ControlGroupId \
      -p CPUAccounting -p CPUWeight -p CPUQuotaPerSecUSec -p CPUQuotaPeriodUSec \
      -p AllowedCPUs -p AllowedMemoryNodes \
      -p MemoryAccounting -p MemoryMax -p MemoryHigh -p MemoryLow -p MemoryMin \
      -p MemorySwapMax -p IOAccounting -p IOWeight \
      -p TasksAccounting -p TasksMax -p Delegate \
    | sed 's/=/\t/' \
    | while IFS='=' read -r k v; do printf '%s\t%s\n' "$k" "$v"; done
) | column -t -s $'\t' 2>/dev/null || cat

echo
echo "(infinity = no limit; Delegate=yes = kubelet lets runtime write sub-cgroups)"