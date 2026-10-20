#!/usr/bin/env bash
#
# sweep-kubectl-logs.sh — recover a log that kubelet refuses to parse, from
# two independent sources.
#
# SOURCE 1 — successful windows.
#   --tail=N moves the line kubelet's format sniffer starts on (it seeks to the
#   Nth line from the END). A window whose landing line looks parseable
#   succeeds; once detection passes, later malformed lines are only warned
#   about, so they come back inside the window.
#
# SOURCE 2 — leaked lines from the failures.
#   When detection fails, kubelet quotes the landing line into the error:
#      failed to get parse function: unsupported log format: "<line>"
#   That is a one-line read primitive. N = 1..MAX leaks line (N-1)-from-the-end
#   on every failure, so MAX calls recover the whole tail even when no window
#   ever succeeds. For a file that is foreign content end to end (leaked key
#   material, shell capture) this is the only source that yields data.
#
# Usage:
#   ./sweep-kubectl-logs.sh <pod> [-n NS] [-c CONTAINER] [opts]
#   ./sweep-kubectl-logs.sh <ns>/<pod> [opts]
#
# Options:
#   -n, --namespace NS   Kubernetes namespace (default: "default")
#   -c, --container NAME Container (auto-picked if the pod has only one)
#   -p, --previous       Sweep the PREVIOUS container instance (after a restart)
#       --max N          Largest --tail to try (default: 50) = lines recoverable
#       --from N         Smallest --tail to try (default: 1)
#       --desc           Sweep descending, stop at first success (fast path)
#       --delay SEC      Sleep between calls (default: 0)
#       --leaks-only     Ignore successful windows; merge leaked error lines only
#       --dump-errors DIR  Save each n's raw stderr to DIR/n<N>.err
#       --probe          Report what each window actually returns, then exit
#       --verbose        Print one line per N (default: compact summary)
#       --gaps           Report gaps in the recovered coverage
#       --summary-only   Report only, no merged log
#       --raw            Merged log only, no commentary
#   -h, --help           This help
#
# CLASSIFICATION PER WINDOW
#   OK     >=1 line returned            -> lines consumed
#   EMPTY  exit 0, 0 bytes              -> nothing to consume (see NOTE)
#   LEAK   format error, line quoted    -> quoted line recovered
#   FAIL   any other error              -> RBAC, no such container, ...
#
# NOTE ON EMPTY WINDOWS
#   "OK, 0 lines" for every N means the log file is EMPTY right now — the
#   content you are chasing has already been rotated or the container
#   restarted. There is nothing to read and nothing to leak, so a sweep cannot
#   help. Check, in this order:
#     ./sweep-kubectl-logs.sh <pod> -n NS -c CTR --probe         # confirms it
#     kubectl logs <pod> -n NS -c CTR --previous --tail=50       # prior instance
#     ssh <node> -- sudo ls -la /var/log/pods/<ns>_<pod>_<uid>/<ctr>/
#                                                                # 0.log.1.gz ...
#
# MERGE KEY
#   Windows and leaks are both indexed by DISTANCE-FROM-END, so they compare
#   without knowing the file length: a leaked line from --tail=N sits at
#   distance N-1; line i of a successful window sits at N-1-i. Distance 0 is
#   the last line of the file. Output prints in descending distance, which
#   reconstructs the file top-to-bottom.

set -uo pipefail

note() { printf '\033[1;34m[*]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,62p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }

# ------------------------------------------------------------------ args
POD=""; NS=""; CTR=""
MAXN=50; FROMN=1
DESC=0; DELAY=0; GAPS=0; RAWMODE=0; SUMMARY_ONLY=0; LEAKS_ONLY=0
DUMPDIR=""; PROBE=0; VERBOSE=0; PREV=0

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--namespace) NS="${2:-}";  [ -n "$NS" ]  || { echo "err: -n needs a value" >&2; exit 2; }; shift 2 ;;
        -c|--container) CTR="${2:-}"; [ -n "$CTR" ] || { echo "err: -c needs a value" >&2; exit 2; }; shift 2 ;;
        -p|--previous)  PREV=1; shift ;;
        --max)          MAXN="${2:-}";  shift 2 ;;
        --from)         FROMN="${2:-}"; shift 2 ;;
        --desc)         DESC=1; shift ;;
        --delay)        DELAY="${2:-0}"; shift 2 ;;
        --leaks-only)   LEAKS_ONLY=1; shift ;;
        --dump-errors)  DUMPDIR="${2:-}"; [ -n "$DUMPDIR" ] || { echo "err: --dump-errors needs a dir" >&2; exit 2; }; shift 2 ;;
        --probe)        PROBE=1; shift ;;
        --verbose)      VERBOSE=1; shift ;;
        --gaps)         GAPS=1; shift ;;
        --summary-only) SUMMARY_ONLY=1; shift ;;
        --raw)          RAWMODE=1; shift ;;
        -h|--help)      usage 0 ;;
        --) shift; break ;;
        -*) echo "err: unknown option $1" >&2; usage ;;
        *)  if [ -z "$POD" ]; then POD="$1"; else echo "err: unexpected arg $1" >&2; usage; fi; shift ;;
    esac
done

[ -n "$POD" ] || usage
case "$POD" in */*) NS="${POD%%/*}"; POD="${POD##*/}" ;; esac
if [ -z "$NS" ]; then
    NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
    [ -n "$NS" ] || NS="default"
fi

case "${MAXN:-x}"  in ''|*[!0-9]*) die "--max must be a number" ;; esac
case "${FROMN:-x}" in ''|*[!0-9]*) die "--from must be a number" ;; esac
[ "$MAXN" -ge "$FROMN" ] || die "--max ($MAXN) must be >= --from ($FROMN)"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
[ -n "$DUMPDIR" ] && mkdir -p "$DUMPDIR"

TMPERR=$(mktemp); TMPSUM=$(mktemp); TMPWIN=$(mktemp)
trap 'rm -f "$TMPERR" "$TMPSUM" "$TMPWIN"' EXIT

# ------------------------------------------------------------------ leak parser
# The failure text is Go-quoted between the last pair of double quotes, so
# \n, \t, \" and \\ inside it are escapes, not literal characters.
extract_leak() {
    local f="$1" raw
    grep -q 'unsupported log format' "$f" || return 1

    raw=$(sed -n 's/.*unsupported log format: "\(.*\)"[[:space:]]*$/\1/p' "$f" | head -1)
    [ -n "$raw" ] || raw=$(sed -n 's/.*unsupported log format: "\(.*\)$/\1/p' "$f" | head -1)
    [ -n "$raw" ] || return 1

    # Explicit left-to-right walk. printf '%b' is NOT sufficient: it handles
    # \n \t \\ but leaves \" alone, corrupting every line with a double quote.
    printf '%s' "$raw" | awk '
        function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }
        {
            s = $0; out = ""; n = length(s)
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (c != "\\") { out = out c; continue }
                i++
                d = substr(s, i, 1)
                if      (d == "n")  out = out "\n"
                else if (d == "t")  out = out "\t"
                else if (d == "r")  out = out "\r"
                else if (d == "\\") out = out "\\"
                else if (d == "\"") out = out "\""
                else if (d == "\047") out = out "\047"
                else if (d == "a")  out = out sprintf("%c", 7)
                else if (d == "b")  out = out sprintf("%c", 8)
                else if (d == "f")  out = out sprintf("%c", 12)
                else if (d == "v")  out = out sprintf("%c", 11)
                else if (d == "x") {
                    h1 = substr(s, i + 1, 1); h2 = substr(s, i + 2, 1)
                    i += 2
                    out = out sprintf("%c", hexval(h1) * 16 + hexval(h2))
                }
                else out = out d
            }
            printf "%s", out
        }'
}

# ------------------------------------------------------------------ container pick
CONTAINERS=$(kubectl get pod "$POD" -n "$NS" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null) \
    || die "cannot read pod $NS/$POD"

if [ -z "$CTR" ]; then
    N=$(printf '%s\n' "$CONTAINERS" | grep -c . || true)
    if [ "$N" -eq 1 ]; then
        CTR=$(printf '%s\n' "$CONTAINERS" | grep . | head -1)
        [ "$RAWMODE" = 0 ] && note "container: $CTR"
    elif [ "$N" -eq 0 ]; then
        die "pod lists no containers"
    else
        warn "pod has multiple containers; pick one with -c"
        printf '  %s\n' $CONTAINERS >&2
        exit 2
    fi
fi

LOGARGS=(logs "$POD" -n "$NS" -c "$CTR")
[ "$PREV" = 1 ] && LOGARGS+=(--previous)

# ------------------------------------------------------------------ probe
if [ "$PROBE" = 1 ]; then
    printf '%-6s %-6s %-14s %-14s %s\n' N EXIT STDOUT_BYTES STDERR_BYTES NOTE
    for n in 1 2 3 5 10 "$MAXN"; do
        kubectl "${LOGARGS[@]}" --tail="$n" >"$TMPWIN" 2>"$TMPERR"
        rc=$?
        ob=$(wc -c <"$TMPWIN"); eb=$(wc -c <"$TMPERR")
        cls="OK"
        if [ "$rc" -ne 0 ]; then
            if grep -q 'unsupported log format' "$TMPERR"; then cls="LEAK"
            else cls="FAIL"; fi
        elif [ "$ob" -eq 0 ]; then
            cls="EMPTY"
        fi
        note_txt=""
        [ -s "$TMPERR" ] && note_txt=$(head -c 56 "$TMPERR" | tr '\n' ' ')
        [ -z "$note_txt" ] && [ "$ob" -gt 0 ] && \
            note_txt=$(head -c 56 "$TMPWIN" | tr '\n' ' ')
        printf '%-6s %-6s %-14s %-14s %s\n' "$n" "$rc" "$ob" "$eb" "$cls $note_txt"
    done
    echo
    echo "read this:"
    echo "  every row EMPTY            -> log file is empty right now; try --previous"
    echo "  rows LEAK                  -> error text carries the landing line; sweep it"
    echo "  rows FAIL                  -> not a format problem; read the message"
    echo "  stdout bytes > 0 on LEAK   -> error went to stdout with exit 0;"
    echo "                                the sweep already handles that case"
    exit 0
fi

# ------------------------------------------------------------------ sweep
declare -A LINES      # distance-from-end -> line text
declare -A SRC        # distance-from-end -> win:<n> | leak:<n>
CONFLICTS=0
N_OK=0; N_EMPTY=0; N_LEAK=0; N_FAIL=0
BYTES_TOTAL=0
CUR_N=0

if [ "$DESC" = 1 ]; then RANGE=$(seq "$MAXN" -1 "$FROMN")
else                     RANGE=$(seq "$FROMN" "$MAXN"); fi

for n in $RANGE; do
    CUR_N=$n
    kubectl "${LOGARGS[@]}" --tail="$n" >"$TMPWIN" 2>"$TMPERR"
    rc=$?
    [ -n "$DUMPDIR" ] && cp "$TMPERR" "$DUMPDIR/n$n.err"
    OB=$(wc -c <"$TMPWIN")
    BYTES_TOTAL=$((BYTES_TOTAL + OB))

    # --- error text that arrived on stdout with exit 0 -------------------
    # Some kubelet builds surface the format error there. Treat as a leak so
    # the error string is never mistaken for log content.
    if [ "$rc" -eq 0 ] && grep -q 'unsupported log format' "$TMPWIN"; then
        rc=1
        cp "$TMPWIN" "$TMPERR"
    fi

    if [ "$rc" -ne 0 ]; then
        # ---- failure: mine the error for the leaked landing line ----
        if LEAK=$(extract_leak "$TMPERR") && [ -n "$LEAK" ]; then
            d=$(( n - 1 ))
            if [ -n "${LINES[$d]+x}" ]; then
                [ "${LINES[$d]}" != "$LEAK" ] && CONFLICTS=$((CONFLICTS + 1))
                N_LEAK=$((N_LEAK + 1))
                [ "$VERBOSE" = 1 ] && printf 'n=%-4s LEAK  (dup) %s\n' "$n" "$LEAK" >>"$TMPSUM"
            else
                LINES[$d]="$LEAK"; SRC[$d]="leak:$n"
                N_LEAK=$((N_LEAK + 1))
                [ "$VERBOSE" = 1 ] && printf 'n=%-4s LEAK  %s\n' "$n" "$LEAK" >>"$TMPSUM"
            fi
        else
            N_FAIL=$((N_FAIL + 1))
            if [ "$VERBOSE" = 1 ]; then
                m=$(head -c 70 "$TMPERR" | tr '\n' ' ')
                printf 'n=%-4s FAIL  %s\n' "$n" "${m:-(empty stderr)}" >>"$TMPSUM"
            fi
        fi
        [ "$DELAY" != "0" ] && sleep "$DELAY"
        continue
    fi

    # ---- success: consume the window ----
    if [ "$OB" -eq 0 ]; then
        # exit 0 with zero bytes: the file is empty at this offset. Storing
        # anything here would manufacture a bogus distance-0 entry.
        N_EMPTY=$((N_EMPTY + 1))
        [ "$VERBOSE" = 1 ] && printf 'n=%-4s EMPTY (0 bytes)\n' "$n" >>"$TMPSUM"
    elif [ "$LEAKS_ONLY" = 1 ]; then
        N_OK=$((N_OK + 1))
        [ "$VERBOSE" = 1 ] && printf 'n=%-4s OK    (ignored: --leaks-only)\n' "$n" >>"$TMPSUM"
    else
        idx=0
        while IFS= read -r line; do
            d=$(( n - 1 - idx ))
            [ "$d" -lt 0 ] && d=0
            if [ -n "${LINES[$d]+x}" ]; then
                [ "${LINES[$d]}" != "$line" ] && CONFLICTS=$((CONFLICTS + 1))
            else
                LINES[$d]="$line"; SRC[$d]="win:$n"
            fi
            idx=$((idx + 1))
        done <"$TMPWIN"
        N_OK=$((N_OK + 1))
        [ "$VERBOSE" = 1 ] && printf 'n=%-4s OK    %s line(s)\n' "$n" "$idx" >>"$TMPSUM"
    fi

    [ "$DESC" = 1 ] && break
    [ "$DELAY" != "0" ] && sleep "$DELAY"
done

# ------------------------------------------------------------------ merge
# `${#LINES[@]}` trips "unbound variable" under set -u when nothing was ever
# stored, so drop nounset for that expansion. (`${#LINES[@]:-0}` is a *bad
# substitution*: a default cannot be attached to an array-length expansion.)
set +u
NLINES=${#LINES[@]}
set -u
[ -n "${NLINES:-}" ] || NLINES=0

if [ "$NLINES" -gt 0 ]; then
    ALLD=$(printf '%s\n' "${!LINES[@]}" | sort -rn)
    FIRSTD=$(printf '%s\n' "$ALLD" | head -1)
    LASTD=$(printf '%s\n' "$ALLD" | tail -1)
else
    ALLD=""; FIRSTD=""; LASTD=""
fi

emit() {
    [ "$NLINES" -gt 0 ] || return 0
    while read -r d; do
        [ -n "$d" ] || continue
        printf '%s\n' "${LINES[$d]}"
    done <<<"$ALLD"
}

if [ "$RAWMODE" = 1 ]; then
    emit
    exit 0
fi

# ------------------------------------------------------------------ report
{
    echo
    echo "==============================================================="
    echo " sweep summary"
    echo "==============================================================="
    echo "pod/container : $NS/$POD  $CTR"
    echo "instance      : $([ "$PREV" = 1 ] && echo PREVIOUS || echo current)"
    echo "range tried   : --tail=$FROMN .. --tail=$MAXN  ($([ "$DESC" = 1 ] && echo descending || echo ascending))"
    echo "windows       : OK=$N_OK  EMPTY=$N_EMPTY  LEAK=$N_LEAK  FAIL=$N_FAIL"
    echo "stdout total  : $BYTES_TOTAL bytes across all windows"
    echo "lines merged  : $NLINES"
    if [ "$NLINES" -gt 0 ]; then
        echo "coverage      : distance-from-end $LASTD .. $FIRSTD  (end-aligned)"
    fi
    [ "$CONFLICTS" -gt 0 ] && \
      echo "CONFLICTS     : $CONFLICTS  (same offset, different text -> rotated mid-sweep)"
    echo

    if [ "$NLINES" -eq 0 ]; then
        if [ "$N_EMPTY" -gt 0 ] && [ "$N_OK" -eq 0 ] && [ "$N_LEAK" -eq 0 ] && [ "$N_FAIL" -eq 0 ]; then
            cat <<EOF
Nothing to recover: EVERY window returned exit 0 with 0 bytes. The log file is
empty at this moment, so there is no content to read and no error to leak --
a sweep cannot help. The text you are after has been rotated away or the
container restarted. Check these, in order:

  1. confirm with raw numbers:
       $(basename "$0") $POD $([ "$NS" != default ] && echo "-n $NS") -c $CTR --probe

  2. the PREVIOUS container instance usually still holds it:
       $(basename "$0") $POD $([ "$NS" != default ] && echo "-n $NS") -c $CTR --previous --max $MAXN

  3. rotated files on the node:
       kubectl logs $POD $([ "$NS" != default ] && echo "-n $NS") -c $CTR --previous
       ssh <node> -- sudo ls -la /var/log/pods/${NS}_${POD}_*/${CTR}/
       # 0.log, 0.log.1, 0.log.2.gz ...  and the <restart>-<time>.log.* names
EOF
        else
            cat <<EOF
Nothing recovered, and the window mix was OK=$N_OK EMPTY=$N_EMPTY LEAK=$N_LEAK
FAIL=$N_FAIL. Re-run with --probe to see exactly what each N returns, and with
--dump-errors DIR to keep the raw stderr for each call.
EOF
        fi
    else
        if [ "$N_LEAK" -gt 0 ] && [ "$N_OK" -eq 0 ]; then
            echo "Recovered entirely from leaked error strings — every window failed,"
            echo "but each failure quoted line N-1 from the end."
            echo
        fi
        if [ "$VERBOSE" = 1 ]; then
            echo "per-n results:"
            sed 's/^/  /' "$TMPSUM"
        else
            echo "per-n results suppressed (use --verbose). source mix:"
            printf '%s\n' "$ALLD" | while read -r d; do
                [ -n "$d" ] || continue
                echo "  d=$d ${SRC[$d]}"
            done | head -20
        fi
    fi

    UID_=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.metadata.uid}' 2>/dev/null)
    NODE=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    cat <<EOF

ground truth (leaked lines can be truncated by kubelet — verify here):
  ssh $NODE -- sudo tail -n $MAXN /var/log/pods/${NS}_${POD}_${UID_}/${CTR}/0.log
  # or
  ./parse-kubectl-logs.sh $POD -n $NS -c $CTR --raw
EOF

    if [ "$GAPS" = 1 ] && [ "$NLINES" -gt 0 ]; then
        echo
        echo "coverage gaps:"
        prev=""
        while read -r d; do
            [ -n "$d" ] || continue
            if [ -n "$prev" ] && [ $(( prev - d )) -gt 1 ]; then
                echo "  missing distance $(( d + 1 )) .. $(( prev - 1 ))"
            fi
            prev="$d"
        done <<<"$ALLD"
    fi

    echo
    echo "--- merged log (descending distance = file order) ---------------------"
} >&2

if [ "$SUMMARY_ONLY" = 0 ]; then
    emit
fi