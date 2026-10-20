#!/usr/bin/env bash
#
# list-mount-propagation.sh — inventory mount-namespace exposure of running pods
#
# Usage:
#   ./list-mount-propagation.sh                  # all namespaces
#   ./list-mount-propagation.sh <k8s-ns>           # one Kubernetes namespace
#
# A container's mount namespace is ALWAYS separate from host's (there
# is no "hostMount" flag).  What varies is mount PROPAGATION, which
# decides whether mounts cross the boundary:
#
#   None            DEFAULT.  Nothing propagates; container mount ns private.
#   HostToContainer Host -> container (one-way in).
#   Bidirectional   Both ways: mounts made in container appear on HOST.
#                   Docs: "only allowed in privileged containers" -> escape vector.
#
# Requires: kubectl, jq (optional: column from util-linux, for alignment)

set -uo pipefail

NS="${1:-}"

if [ -n "$NS" ]; then
    SCOPE=(-n "$NS")
    SCOPE_LABEL="namespace=$NS"
else
    SCOPE=(--all-namespaces)
    SCOPE_LABEL="all namespaces"
fi

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }

if command -v column >/dev/null 2>&1; then
    align() { column -t -s $'\t'; }
else
    align() { cat; }
fi

PODS=$(kubectl get pods "${SCOPE[@]}" --field-selector=status.phase=Running -o json)

if [ -z "$PODS" ]; then
    echo "Error: kubectl returned nothing (no cluster / no RBAC?)" >&2
    exit 1
fi

cat <<EOF
=================================================================
 Mount propagation / mount namespace — $SCOPE_LABEL
=================================================================
Legend (volumeMounts[].mountPropagation):
  None            DEFAULT.  Nothing propagates; container mount ns private.
  HostToContainer Host mounts under path appear INSIDE container (one-way).
  Bidirectional   Both ways: mounts made in container appear on HOST.
                  Docs: "only allowed in privileged containers" -> escape vector.
  - Not set in manifest; runtime treats as None.

NOTE: container mount namespace is always separate from host's.
      Only propagation (plus privileged / hostPath) lets anything cross.
EOF

# ---------- Section A: volumeMounts that USE mount propagation ----------
echo
echo "--- A. volumeMounts that use mountPropagation (non-None) ---"
echo

A_OUT=$(echo "$PODS" | jq -r '
  (.items[]) as $p
  | ($p.spec.volumes // []) as $vols
  | (($p.spec.initContainers // []) + ($p.spec.containers // []) + ($p.spec.ephemeralContainers // []))[] as $c
  | ($c.volumeMounts // [])[] as $m
  | select(($m.mountPropagation // "None") != "None")
  | ($vols[] | select(.name == $m.name) | .hostPath.path // "-") as $hp
  | (($c.securityContext.privileged // false) | tostring) as $priv
  | [ $p.metadata.namespace, $p.metadata.name, $c.name, $m.name,
      ($m.mountPropagation // "None"), $m.mountPath, $hp, $priv ]
  | @tsv
')

if [ "$(printf '%s\n' "$A_OUT" | wc -l)" -le 1 ]; then
    echo " (none — no running pod sets mountPropagation)"
else
    printf '%s\n' "$A_OUT" | align
fi

# ---------- Section B: Propagation value counts ----------
echo
echo "--- B. Propagation value counts (every volumeMount, all containers) ---"
echo
echo "$PODS" | jq -r '
  .items[] as $p
  | (($p.spec.initContainers // []) + ($p.spec.containers // []) + ($p.spec.ephemeralContainers // []))[]
  | (.volumeMounts // [])[]
  | (.mountPropagation // "None")
' | sort | uniq -c | sort -rn

# ---------- Section C: Mount-ns manipulation surface ----------
echo
echo "--- C. Mount-ns manipulation surface (privileged / CAP_SYS_ADMIN / procMount=Unmasked) ---"
echo " (privileged:true implies CAP_SYS_ADMIN even if not listed in capabilities.add)"
echo

C_OUT=$(echo "$PODS" | jq -r '
  .items[] as $p
  | (($p.spec.initContainers // []) + ($p.spec.containers // []) + ($p.spec.ephemeralContainers // []))[] as $c
  | ($c.securityContext // {}) as $sc
  | select(
      ($sc.privileged // false) or
      (($sc.capabilities.add // []) | index("SYS_ADMIN")) != null or
      (($sc.procMount // "Default") == "Unmasked")
    )
  | [ $p.metadata.namespace, $p.metadata.name, $c.name,
      (($sc.privileged // false) | tostring),
      (($sc.capabilities.add // []) | index("SYS_ADMIN") != null | tostring),
      ($sc.procMount // "Default"),
      (($c.volumeMounts // []) | length | tostring) ]
  | @tsv
')

if [ "$(printf '%s\n' "$C_OUT" | wc -l)" -le 1 ]; then
    echo " (none)"
else
    printf '%s\n' "$C_OUT" | align
fi

# ---------- Section D: recursiveReadOnly cross-check ----------
echo
echo "--- D. recursiveReadOnly vs mountPropagation cross-check (INVALID=violation) ---"
echo

D_OUT=$(echo "$PODS" | jq -r '
  .items[] as $p
  | ($p.spec.volumes // []) as $vols
  | (($p.spec.initContainers // []) + ($p.spec.containers // []) + ($p.spec.ephemeralContainers // []))[] as $c
  | ($c.volumeMounts // [])[] as $m
  | ($m.mountPropagation // "None") as $mp
  | ($m.recursiveReadOnly // null) as $rro
  | select($rro != null and $rro != "Disabled")
  | select($mp == "Bidirectional")
  | [ $p.metadata.namespace, $p.metadata.name, $c.name, $m.name,
      $rro, $mp, "INVALID" ]
  | @tsv
')

if [ "$(printf '%s\n' "$D_OUT" | wc -l)" -le 1 ]; then
    echo " (none)"
else
    printf '%s\n' "$D_OUT" | align
fi

echo
echo "Declared spec values. Verify at runtime:"
echo "  inside container: findmnt -o TARGET,PROPAGATION"
echo "  from host, per PID: grep -E ' (shared|private|slave):' /proc/<pid>/mountinfo"
echo "  nsenter it: nsenter -t <pid> -m findmnt -o TARGET,PROPAGATION"