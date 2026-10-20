#!/usr/bin/env bash
#
# cgroup-values.sh — configured + enforced cgroup systemd units.
#
# Usage:
#   ./cgroup-values.sh                       # all kubepods-*.slice
#   ./cgroup-values.sh 'kube-*.service'     # control-plane units
#   ./cgroup-values.sh 'kubepods-burstable-pod*.slice'
#
# Needs root /sys/fs/cgroup reads.  systemd >= 230 for --value.

set -uo pipefail

PATTERN="${1:-kubepods-*}"

if command -v column >/dev/null 2>&1; then
    align() { column -t -s $'\t'; }
else
    align() { cat; }
fi

printf '%-52s %-8s %-12s %-12s %-12s %-8s %-9s\n' \
    UNIT CPU_W CPU_MAX MEM_MAX MEM_HIGH PIDS_MAX DELEGATE

systemctl list-units --type=slice --all --no-legend --plain "$PATTERN" 2>/dev/null \
| awk '{print $1}' \
| while read -r u; do
    [ -n "$u" ] || continue
    cg=$(systemctl show "$u" -p ControlGroup --value 2>/dev/null)
    [ -n "$cg" ] || continue
    root="/sys/fs/cgroup$cg"
    rd() { [ -f "$root/$1" ] && cat "$root/$1" 2>/dev/null || echo "-"; }
    printf '%-52s %-8s %-12s %-12s %-12s %-8s %-9s\n' \
      "$u" \
      "$(rd cpu.weight)" \
      "$(rd cpu.max)" \
      "$(rd memory.max)" \
      "$(rd memory.high)" \
      "$(rd pids.max)" \
      "$(systemctl show "$u" -p Delegate --value 2>/dev/null)"
done | align

echo
echo "defaults: cpu.weight=100 | cpu.max='max 100000' (unlimited) | memory.max=max | pids.max=max"
echo "note: value NOT written by kubelet/systemd shows inherited default, not request."