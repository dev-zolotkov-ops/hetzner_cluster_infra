# Monitoring Storage Recovery

`install.sh` runs `storage/recover_monitoring_volumes.py` immediately after CSI installation and before the monitoring Helm releases. The step is idempotent and uses a fail-closed policy:

- On an empty cluster with no old volumes found, no PV is created, so CSI continues dynamic provisioning.
- A volume is accepted only when its CSI labels `pvc-name` and `pvc-namespace` match one of the five expected claims. For a long name, left truncation to the last 63 characters is allowed.
- When both an old and a new volume exist for one claim, the legacy ID is selected. If it is absent, exactly one role-tagged candidate or exactly one other candidate is required. Ambiguity, missing identity for a known legacy ID, an incorrect size/location, a selected legacy volume that is attached, or a Kubernetes binding conflict stops the bootstrap.
- The recovered PV uses CSI `csi.hetzner.cloud`, StorageClass `hcloud-volumes`, RWO, `ext4`, `Retain`, zone affinity, and the exact `claimRef`.

The registry is in `storage/monitoring-volume-registry.json`; it specifies five claims and legacy IDs. Sizes are not duplicated in the registry. The optional label `cluster-infra-pvc-id=<role>` is checked against CSI labels and is not an identity by itself.

Sizes, persistence enablement, StorageClass, and replica count are read from the vendored Helm values on every run:

- `helm/kube-prometheus-stack/values.yaml` for Grafana and Prometheus;
- `helm/loki/values-final-work.yaml` for Loki;
- `helm/tempo/values-final-work.yaml` for Tempo.

The `fsn1` location is specified in the registry, not in the Helm values. The script requires Python 3 and PyYAML and stops for an invalid YAML structure, disabled persistence, an unsuitable StorageClass, incorrect replica counts, or a non-positive Gi size.

Offline manifest check:

```bash
python3 storage/recover_monitoring_volumes.py \
  --volumes-json /path/to/verified-hcloud-volume-list.json --print-manifest
```

The JSON must contain only the necessary fields from the volume list, such as `id`, `size`, `location`, and `labels`. Do not store tokens or API responses containing secrets.

After monitoring installation, `install.sh` obtains a new authoritative volume list, checks all five PVCs and CSI handles, sets `Retain` for bound PVs, adds a short role label only to the selected volumes, and checks the labels again. Foreign and orphan volumes are not modified. A replacement must not be matched solely by size or age.

Manual post-check:

```bash
hcloud volume list -o json > /tmp/volumes.json
python3 storage/recover_monitoring_volumes.py --post --volumes-json /tmp/volumes.json
```

`--print-manifest` mode makes no changes. After Kubernetes checks, post mode uses `hcloud volume add-label <id> cluster-infra-pvc-id=<role>` and verifies the result with a fresh volume list.
