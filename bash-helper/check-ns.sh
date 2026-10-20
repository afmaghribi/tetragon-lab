#!/usr/bin/env bash
#
# check-ns.sh — compare a target PID's namespaces against host PID 1
#
# Usage: ./check-ns.sh <pid>
#   e.g. ./check-ns.sh 12345
#
# Run from host root (or with CAP_SYS_PTRACE / same user) so /proc/<pid>/ns
# is readable. Namespaces that read the same inode are SHARED with the host;
# different inodes mean the target is ISOLATED in that namespace.

set -u

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <pid>" >&2
    exit 1
fi

PID="$1"

if [ ! -d "/proc/$PID" ]; then
    echo "Error: PID $PID does not exist" >&2
    exit 1
fi

echo "Host PID 1 vs target PID $PID"
echo "---------------------------------------------"

for ns in cgroup ipc mnt net pid user uts; do
    host=$(readlink "/proc/1/ns/$ns" 2>/dev/null)
    container=$(readlink "/proc/$PID/ns/$ns" 2>/dev/null)

    if [ -z "$host" ] || [ -z "$container" ]; then
        echo "$ns: UNREADABLE (permission denied or ns missing)"
    elif [ "$host" = "$container" ]; then
        echo "$ns: SHARED      ($host)"
    else
        echo "$ns: ISOLATED    host=$host  container=$container"
    fi
done