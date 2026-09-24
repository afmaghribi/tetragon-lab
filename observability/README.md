# Tetragon → Loki → Grafana observability stack

Ships Tetragon's JSON events into **Loki** so Grafana dashboards such as
[Tetragon "kubectl exec" Audit (20189)](https://grafana.com/grafana/dashboards/20189-tetragon-kubectl-exec-audit/)
work out of the box.

```
Tetragon agent (already running)
  └─ file export: /var/run/cilium/tetragon/tetragon.log   (hostPath, JSON/line)
        │  (DaemonSet hostPath, one Alloy per node)
        ▼
Alloy ── loki.source.file + loki.process ──► Loki (single binary)
        ▼
Grafana (Loki datasource) ── dashboard 20189
```

## Why this shape

- The Tetragon agent has **no native Loki output** (verified `--help`: only
  file export + gRPC server). The export file is always present at
  `/var/run/cilium/tetragon/tetragon.log` because of the `export-logs`
  hostPath volume (DirectoryOrCreate) in the tetragon DaemonSet.
- **Alloy** (Grafana Agent) tails that file and pushes to Loki with the two
  labels the dashboard's variables read:
  - `job`       → `$export_job`   (static: `tetragon`)
  - `cluster`   → `$cluster`      (static: set the cluster name)
  - `namespace` → `$namespace`    (extracted from the JSON event)
- Loki is required regardless of the shipper because the dashboard speaks
  **LogQL** (Grafana: not VictoriaMetrics, not VictoriaLogs without rewriting
  all queries).

## Files

| File | Purpose |
|------|---------|
| `10-loki.yaml` | Loki v3.5.4 single binary in `monitoring` (ConfigMap config + PVC via local-path + Deployment + ClusterIP svc :3100) |
| `20-alloy-tetragon.yaml` | Alloy v1.19.2 DaemonSet + ConfigMap: tails the tetragon export file, adds `job`/`cluster`/`namespace` labels, pushes to Loki |
| `apply.sh` | convenience applier |

## Deploy

```sh
kubectl apply -f 10-loki.yaml
kubectl apply -f 20-alloy-tetragon.yaml
# check both:
kubectl -n monitoring get pods | grep -E "loki|alloy"
# generate exec events, then check Loki received them:
curl -s "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/labels/job/values"
```

## Grafana wiring

1. **Connections → Data sources → Loki**:
   URL `http://loki.monitoring.svc.cluster.local:3100`.
2. **Dashboards → Import 20189** (Isovalent "Tetragon kubectl exec audit").
   On import, map `DS_GRAFANACLOUD-ISOVALENT-LOGS` to the new Loki DS.
3. **`container_runtime` variable gotcha**: the panel filters
   `process_exec_parent_binary=\`$container_runtime\`` (default
   `/usr/sbin/runc`). On containerd/Ubuntu the parent of a `kubectl exec`
   process is usually **`/usr/bin/containerd-shim-runc-v2`** — set the
   variable to match your node, otherwise rows stay empty. Check the actual
   value your events carry:
   ```sh
   curl -sG http://loki.monitoring.svc.cluster.local:3100 \
     --data-urlencode 'query={job="tetragon"} | json | line_format "{{.process_exec_parent_binary}}"' \
     --data-urlencode 'limit=5' | python3 -m json.tool
   ```
4. Then run `kubectl exec` in any pod: the audit table shows all
   execs with parent != 1 (i.e. *your* interactive execs, not liveness probes).

## Notes

- `imagePullPolicy: IfNotPresent`; both images must be pulled once.
- Loki storage: **PVC via local-path-provisioner** (already in cluster),
  5Gi; single binary with `replication_factor: 1`; auth disabled.
- Alloy runs on **every node** (DaemonSet) since the tetragon export file is
  per-node; label `node` is added via the downward API for per-node filtering.
- Trim noise the same way tetragon's denylist does
  (`kube-system`, `cilium` namespaces are excluded at the agent already; the
  Alloy pipeline passes everything else through).

## Reminders for testing with the escape scenarios

Because Tetragon watches for `process_exec`, the escape/`kubectl exec`
events you demo in `container-escape/` (including the kubelet-API execs)
show up here — nice for the "observe → analyze → enforce" story, alongside
the TracingPolicies in `../policy/`.

Coverage per scenario:

| Scenario | Policy | Dashboard surface |
|----------|--------|-------------------|
| `01-privileged-workload-scenario` | `container-escape-detection.yaml` (`host-disk-mount`, `static-pod-manifest` tags) | "Escape technique timeline" + "TracingPolicy (kprobe) Events" |
| `02-core-pattern-scenario` | `core-pattern-escape-detection.yaml` — two stages: `core-pattern-overwrite` (openat write to the sysctl) + `core-pattern-exec` (security_bprm_check of the staged handler) | "core_pattern escape stages" panel (splits by `stage`) + timeline |

Alloy ships two technique labels:

- `tag` = `process_kprobe.tags[1]` → technique *family* (`core-pattern`, `host-disk-mount`, `static-pod-manifest`, ...)
- `stage` = `process_kprobe.tags[2]` → *stage within* a technique (`core-pattern-overwrite` vs `core-pattern-exec`)

The alert rule `tetragon-escape-detections` ("Container escape detected ...")
counts events with any of the three tags: `host-disk-mount`,
`static-pod-manifest`, `core-pattern`.

> Note for `02`: stage `-overwrite` fires on the `openat(O_WRONLY/O_TRUNC)` of
> the sysctl — the moment the attacker writes the pipe handler, before any
> crash. Stage `-exec` fires on `security_bprm_check` when the kernel actually
> execs the handler: the staged binary's path resolves through
> `linux_binprm` and matches the containerd overlayfs upperdir prefix
> `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/`.
> That exec runs host-context (parent kthreadd), so it also shows up in the
> "Host-context processes (init tree)" table — exactly why `exportDenyList`
> above stops hiding `""` namespace events.