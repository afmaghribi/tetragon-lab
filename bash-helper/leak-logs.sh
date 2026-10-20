#!/usr/bin/env bash
#
# leak-logs.sh — parse the leaked line out of kubectl's parse error, merge them.
#
#   kubectl logs --tail=N -n NS POD
#   failed to get parse function: unsupported log format: "<line>"
#
# N=1 gives the last line of the file, N=2 the one before it, N=3 the one
# before that, so the loop emits the lines backwards and tac reverses them
# into file order.
#
# The quoted <line> is Go-quoted, so its line terminator shows up as the two
# literal characters \n. That escape IS the line ending, not content, so it is
# stripped and awk's print supplies a real newline.
#
# awk (not sed) does the parsing on purpose: kubectl writes this error with no
# trailing newline, and sed emits an unterminated last line in that case, which
# makes every iteration glue onto the previous one. awk's print always
# terminates with ORS.
#
# Usage: ./leak-logs.sh <pod> [namespace] [max-tail]

POD="${1:?usage: $0 <pod> [namespace] [max-tail]}"
NS="${2:-default}"
MAX="${3:-50}"

for n in $(seq 1 "$MAX"); do
    kubectl logs --tail="$n" -n "$NS" "$POD" 2>&1 | awk '
        {
            i = index($0, "unsupported log format: \"")
            if (i == 0) next
            s = substr($0, i + 25)
            # cut at the last double quote (closing quote of the Go-quoted string)
            j = 0
            for (k = length(s); k >= 1; k--)
                if (substr(s, k, 1) == "\"") { j = k; break }
            if (j > 0) s = substr(s, 1, j - 1)
            sub(/\\n$/, "", s)
            print s
        }'
done | tac