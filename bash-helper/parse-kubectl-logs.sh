#!/usr/bin/env bash
#
# parse-kubectl-logs.sh — fetch container logs with format auto-detection,
# and a node-level fallback for logs kubelet cannot parse.
#
# Usage:
#   ./parse-kubectl-logs.sh <pod> [-n NS] [-c CONTAINER] [opts]
#   ./parse-kubectl-logs.sh <ns>/<pod> [opts]
#
# Options:
#   -n, --namespace NS   Kubernetes namespace (default: "default")
#   -c, --container NAME Container (auto-picked if the pod has only one)
#   -p, --previous       Previous container instance (after a restart)
#       --tail N         Last N lines (default: 200)
#       --since DUR      e.g. 10m, 1h
#       --parse          Normalise to TSV: TIMESTAMP STREAM MESSAGE
#       --scan           Scan for secrets / shell prompts / suspicious content
#       --raw            Skip kubectl entirely; read the file on the node
#       --list           List containers of the pod and exit
#   -h, --help           This help
#
# WHY THE FALLBACK EXISTS
#   kubelet auto-detects the container log format (CRI / JSON / plain) from the
#   first line it reads, then bails with:
#       failed to get parse function: unsupported log format: "<line>"
#   That happens when the log content is not what the runtime wrote — e.g. a
#   symlink swap of the log path, or a direct write into it from the host.
#   Note that with --tail=N the first line read is near the END of the file,
#   so the quoted line is often the last line rather than the first.
#   Workaround: read the file directly on the node (--raw path) or use
#   crictl logs. Both bypass kubelet's parser.

set -uo pipefail

# ------------------------------------------------------------------ helpers
note() { printf '\033[1;34m[*]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-2}"
}

run_post() {
    local in
    in=$(cat)

    if [ "$MODE_PARSE" = 1 ]; then
        echo
        note "parsed view (TIMESTAMP <TAB> STREAM <TAB> MESSAGE)"
        printf '%s\n' "$in" | awk '
            BEGIN { FS="\t"; OFS="\t" }
            # already-normalised TSV (2+ fields) passes through
            NF>=3 && $2 ~ /^(stdout|stderr)$/ { print; next }
            {
                line=$0
                if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z [a-z]+ [FP] /)) {
                    ts=substr(line,1,index(line," ")-1)
                    rest=substr(line,length(ts)+2)
                    split(rest,p," ")
                    stream=p[1]
                    msg=substr(rest,length(stream)+4)
                    print ts, stream, msg
                    next
                }
                if (line ~ /^\{"log":/) {
                    print "-", "json", line
                    next
                }
                print "-", "-", line
            }'
    fi

    if [ "$MODE_SCAN" = 1 ]; then
        echo
        note "scan: secrets / shell prompts / suspicious content"
        printf '%s\n' "$in" | grep -nE -e \
'-----BEGIN [A-Z ]*PRIVATE KEY-----|-----END [A-Z ]*PRIVATE KEY-----|BEGIN CERTIFICATE|'\
'authorized_keys|id_rsa|id_ed25519|\.ssh/|'\
'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|'\
'ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|'\
'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.|'\
'[a-zA-Z0-9_.-]+@[a-zA-Z0-9_.-]+:[^ ]*[#$] |'\
'password=|passwd=|token=' \
        | head -50 || echo "  (no matches)"
    fi
}

# ------------------------------------------------------------------ args
POD=""
NS=""
CTR=""
TAIL=200
SINCE=""
PREV=0
MODE_PARSE=0
MODE_SCAN=0
MODE_RAW=0
MODE_LIST=0

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--namespace) NS="${2:-}"; [ -n "$NS" ] || { echo "err: -n needs a value" >&2; exit 2; }; shift 2 ;;
        -c|--container) CTR="${2:-}"; [ -n "$CTR" ] || { echo "err: -c needs a value" >&2; exit 2; }; shift 2 ;;
        -p|--previous)  PREV=1; shift ;;
        --tail)         TAIL="${2:-}"; [ -n "$TAIL" ] || { echo "err: --tail needs a value" >&2; exit 2; }; shift 2 ;;
        --since)        SINCE="${2:-}"; [ -n "$SINCE" ] || { echo "err: --since needs a value" >&2; exit 2; }; shift 2 ;;
        --parse)        MODE_PARSE=1; shift ;;
        --scan)         MODE_SCAN=1; shift ;;
        --raw)          MODE_RAW=1; shift ;;
        --list)         MODE_LIST=1; shift ;;
        -h|--help)      usage 0 ;;
        --) shift; break ;;
        -*) echo "err: unknown option $1" >&2; usage ;;
        *)  if [ -z "$POD" ]; then POD="$1"; else echo "err: unexpected arg $1" >&2; usage; fi; shift ;;
    esac
done

[ -n "$POD" ] || usage

case "$POD" in
    */*) NS="${POD%%/*}"; POD="${POD##*/}" ;;
esac

if [ -z "$NS" ]; then
    NS=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
    [ -n "$NS" ] || NS="default"
fi

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; else HAVE_JQ=0; fi

TMPERR=$(mktemp)
trap 'rm -f "$TMPERR"' EXIT

# ------------------------------------------------------------------ pod facts
PJSON=$(kubectl get pod "$POD" -n "$NS" -o json 2>/dev/null) \
    || die "pod $NS/$POD not found (or no RBAC to read it)"

if [ "$HAVE_JQ" = 1 ]; then
    NODE=$(printf '%s' "$PJSON" | jq -r '.spec.nodeName // "?"')
    UID_=$(printf '%s' "$PJSON" | jq -r '.metadata.uid')
    PHASE=$(printf '%s' "$PJSON" | jq -r '.status.phase // "?"')
    RESTARTS=$(printf '%s' "$PJSON" | jq -r '[.status.containerStatuses[]?.restartCount] | add // 0')
    CONTAINERS=$(printf '%s' "$PJSON" | jq -r '.spec.containers[]?.name')
    INIT_CONTAINERS=$(printf '%s' "$PJSON" | jq -r '.spec.initContainers[]?.name')
    CID_FIRST=$(printf '%s' "$PJSON" | jq -r '.status.containerStatuses[0].containerID // ""')
else
    NODE=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}')
    UID_=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.metadata.uid}')
    PHASE=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}')
    RESTARTS=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[*].restartCount}')
    CONTAINERS=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')
    INIT_CONTAINERS=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}')
    CID_FIRST=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].containerID}')
fi

# ------------------------------------------------------------------ --list
if [ "$MODE_LIST" = 1 ]; then
    echo "pod:      $NS/$POD"
    echo "node:     $NODE"
    echo "uid:      $UID_"
    echo "phase:    $PHASE"
    echo "restarts: ${RESTARTS:-0}"
    echo
    echo "initContainers:"
    if [ -n "$INIT_CONTAINERS" ]; then printf '  %s\n' $INIT_CONTAINERS; else echo "  (none)"; fi
    echo "containers:"
    if [ -n "$CONTAINERS" ]; then printf '  %s\n' $CONTAINERS; else echo "  (none)"; fi
    echo
    echo "log file on node:"
    echo "  /var/log/pods/${NS}_${POD}_${UID_}/<container>/0.log"
    exit 0
fi

# ------------------------------------------------------------------ container pick
if [ -z "$CTR" ]; then
    N=$(printf '%s\n' "$CONTAINERS" | grep -c . || true)
    if [ "$N" -eq 1 ]; then
        CTR=$(printf '%s\n' "$CONTAINERS" | head -1)
        note "auto-selected container: $CTR"
    elif [ "$N" -eq 0 ]; then
        die "pod lists no containers"
    else
        warn "pod has multiple containers; pick one with -c"
        printf '  %s\n' $CONTAINERS >&2
        exit 2
    fi
fi

# ------------------------------------------------------------------ kubectl attempt
KARGS=(logs "$POD" -n "$NS" -c "$CTR" --tail="$TAIL")
[ -n "$SINCE" ] && KARGS+=(--since="$SINCE")
[ "$PREV" = 1 ] && KARGS+=(--previous)

if [ "$MODE_RAW" = 0 ]; then
    kubectl "${KARGS[@]}" >"$TMPERR.out" 2>"$TMPERR"
    RC=$?
else
    RC=1
    : >"$TMPERR"
fi

if [ "$RC" -eq 0 ]; then
    if [ "$MODE_PARSE" = 1 ] || [ "$MODE_SCAN" = 1 ]; then
        run_post <"$TMPERR.out"
    else
        cat "$TMPERR.out"
    fi
    rm -f "$TMPERR.out"
    exit 0
fi

KERR=$(cat "$TMPERR")
rm -f "$TMPERR.out"

# ------------------------------------------------------------------ diagnose
echo
if printf '%s' "$KERR" | grep -q 'unsupported log format'; then
    warn "kubelet cannot parse this container's log file."
    echo
    OFFENDING=$(printf '%s' "$KERR" \
        | sed -n 's/.*unsupported log format: "\(.*\)"$/\1/p' | head -1)
    if [ -n "$OFFENDING" ]; then
        echo "  offending line: $OFFENDING"
        echo
    fi
    cat <<'EOF'
  Meaning
    kubelet sniffs the log format (CRI / JSON / plain) from the first line it
    reads. That line is not something it recognises, so it refuses to serve
    the file. With --tail=N the first line read is near the END of the file,
    which is why the quoted line is often the last one written.

  Typical cause
    The log content is not what the runtime wrote. Usual suspects:
      - a symlink swap in the log path (log redirection)
      - a direct write into the container log path from the host
      - a truncated or partially rotated file

  Workaround
    kubelet's parser is what is stuck, so bypass it: read the raw file on the
    node, or use crictl logs.
EOF
else
    warn "kubectl logs failed:"
    printf '%s\n' "$KERR" | sed 's/^/    /'
fi

# ------------------------------------------------------------------ fallbacks
echo
note "Attempting node-level fallback..."

LOCAL_HOST=$(hostname)
LOGDIR="/var/log/pods/${NS}_${POD}_${UID_}/${CTR}"
CURRENT="${LOGDIR}/0.log"

try_local() {
    [ -d "$LOGDIR" ] || return 1
    if [ -f "$CURRENT" ]; then
        ok "raw file: $CURRENT"
        if [ "$MODE_PARSE" = 1 ] || [ "$MODE_SCAN" = 1 ]; then
            tail -n "$TAIL" "$CURRENT" 2>/dev/null | run_post
        else
            tail -n "$TAIL" "$CURRENT" 2>/dev/null || return 1
        fi
        return 0
    fi
    local f
    f=$(ls -1t "$LOGDIR"/0.log* 2>/dev/null | head -1)
    [ -n "$f" ] || return 1
    ok "raw file (rotated): $f"
    case "$f" in
        *.gz) zcat "$f" 2>/dev/null | tail -n "$TAIL" ;;
        *)    tail -n "$TAIL" "$f" 2>/dev/null ;;
    esac
}

try_crictl() {
    command -v crictl >/dev/null 2>&1 || return 1
    [ -n "$CID_FIRST" ] || return 1
    ok "crictl logs (bypasses kubelet parser)"
    crictl logs --tail "$TAIL" "${CID_FIRST#*://}" 2>/dev/null
}

try_containers_link() {
    [ -n "$CID_FIRST" ] || return 1
    local cid="${CID_FIRST#*://}"
    local link="/var/log/containers/${POD}_${NS}_${CTR}-${cid}.log"
    [ -e "$link" ] || return 1
    ok "raw file via /var/log/containers symlink: $link"
    cat "$link" 2>/dev/null | tail -n "$TAIL"
}

DONE=0

try_kubectl_direct() {
    # some setups still serve the file despite a parse failure elsewhere
    command -v kubectl >/dev/null 2>&1 || return 1
    kubectl get --raw \
      "/api/v1/namespaces/${NS}/pods/${POD}/log?container=${CTR}&tailLines=${TAIL}" \
      2>/dev/null | head -n "$TAIL" | grep -q . || return 1
    ok "kubectl get --raw log endpoint"
    kubectl get --raw \
      "/api/v1/namespaces/${NS}/pods/${POD}/log?container=${CTR}&tailLines=${TAIL}" \
      2>/dev/null | head -n "$TAIL"
}

if [ "$LOCAL_HOST" = "$NODE" ]; then
    try_local       && DONE=1
    [ "$DONE" = 0 ] && try_crictl           && DONE=1
    [ "$DONE" = 0 ] && try_containers_link  && DONE=1
fi
[ "$DONE" = 0 ] && try_kubectl_direct && DONE=1

if [ "$DONE" = 0 ]; then
    cat <<EOF

  Not on the pod's node ($NODE; this host is $LOCAL_HOST), so the raw file
  cannot be read from here. Run one of these ON $NODE:

    # 1. raw file — bypasses kubelet entirely
    sudo tail -n $TAIL $CURRENT

    # 2. crictl — also bypasses kubelet's parser
    crictl logs --tail $TAIL ${CID_FIRST#*://}

    # 3. container log symlink
    sudo tail -n $TAIL /var/log/containers/${POD}_${NS}_${CTR}-*.log

    # 4. inspect why the file is malformed
    sudo ls -la $LOGDIR/
    sudo file  $CURRENT
    sudo head -c 200 $CURRENT | xxd | head

  Or re-run this script from that node:
    ssh $NODE -- $0 $POD -n $NS -c $CTR --raw
EOF
fi