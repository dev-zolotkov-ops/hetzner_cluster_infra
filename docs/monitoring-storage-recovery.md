# Monitoring Storage Recovery

`install.sh` runs `storage/recover_monitoring_volumes.py` immediately after
the CSI Helm release and before any monitoring chart. The recovery step is
idempotent and fail-closed:

- A bare cluster with no mapped legacy volume creates no PV and keeps dynamic
  provisioning enabled.
- A volume is reusable only when its CSI `pvc-name`/`pvc-namespace` labels
  identify one expected claim (full name or the left-truncated final 63
  characters), and its size and location match exactly.
- If both an old and replacement volume identify a claim, the listed legacy ID
  wins. If it is absent, one correctly role-tagged candidate wins; otherwise
  exactly one remaining candidate is required. Ambiguity, missing identity on
  a known legacy ID, wrong sizes/locations, attached legacy volumes, and
  existing conflicting bindings stop bootstrap.
- Recovered PVs use CSI driver `csi.hetzner.cloud`, `hcloud-volumes`, RWO,
  `ext4`, location node affinity, `Retain`, and an exact `claimRef`.

The registry is `storage/monitoring-volume-registry.json` and contains the
five exact expected claims and legacy IDs. The optional
`cluster-infra-pvc-id=<role>` label is cross-checked against CSI labels; it is
not accepted as identity by itself.

Example offline manifest check:

```bash
python3 storage/recover_monitoring_volumes.py \
  --volumes-json /path/to/verified-hcloud-volume-list.json --print-manifest
```

The JSON must contain only the required volume-list fields, for example
`id`, `size`, `location`, and `labels`. Do not store tokens or API responses
containing secrets in the repository.

The post-monitoring phase fetches a fresh authoritative volume list, verifies
all five PVCs are Bound to the selected CSI handles, protects bound PVs with
`Retain`, adds the short role label only to those five selected volumes, and
re-lists to verify the labels. It never labels foreign or orphan volumes.
Do not map a replacement merely by size or age.

Verification after Helm:

```bash
hcloud volume list -o json > /tmp/volumes.json
python3 storage/recover_monitoring_volumes.py --post --volumes-json /tmp/volumes.json
```

The pre-install `--print-manifest` path performs no mutation. Post mode also
uses `hcloud volume add-label <id> cluster-infra-pvc-id=<role>` after the
Kubernetes handle checks and verifies with a fresh volume list.
