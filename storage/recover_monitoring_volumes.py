#!/usr/bin/env python3
"""Offline-safe pre-install recovery for monitoring CSI volumes.

Identity comes from Hetzner/CSI labels, never from size, age, or list order.
This phase does not mutate Hetzner. Without --print-manifest it may apply PVs
to Kubernetes, which is used by install.sh after CSI has been installed.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import re
from pathlib import Path

try:
    import yaml as _yaml
except ImportError:
    _yaml = None

REGISTRY = Path(__file__).with_name("monitoring-volume-registry.json")
REPO_ROOT = Path(__file__).resolve().parents[1]
CSI = "csi.hetzner.cloud"
PVC_NAME_KEYS = ("pvc-name", "csi.hetzner.cloud/pvc-name")
PVC_NAMESPACE_KEYS = ("pvc-namespace", "csi.hetzner.cloud/pvc-namespace")
CREATED_BY_KEYS = ("created-by", "csi.hetzner.cloud/created-by")
MANAGED_LABEL = "cluster-infra-managed"
ROLE_LABEL = "cluster-infra-pvc-id"


class RecoveryError(RuntimeError):
    pass


def fail(message):
    raise RecoveryError(message)


def load_json(path):
    with Path(path).open(encoding="utf-8") as stream:
        return json.load(stream)


def helm_values(path):
    if _yaml is None:
        fail("PyYAML is required to derive monitoring storage from Helm values")
    assert _yaml is not None
    try:
        with path.open(encoding="utf-8") as stream:
            return _yaml.safe_load(stream)
    except OSError as error:
        fail(f"cannot read Helm values {path}: {error}")
    except Exception as error:
        fail(f"invalid Helm YAML {path}: {error}")


def quantity(value, field):
    match = re.fullmatch(r"([1-9][0-9]*)Gi", str(value or ""))
    if not match:
        fail(f"{field} must be a positive whole Gi quantity")
    return int(match.group(1) if match else 0)


def mapping(value, field):
    if not isinstance(value, dict):
        fail(f"{field} must be a YAML mapping")
    return value


def storage_contract(repo_root=REPO_ROOT):
    stack = mapping(helm_values(repo_root / "helm/kube-prometheus-stack/values.yaml"), "kube-prometheus-stack values")
    loki = mapping(helm_values(repo_root / "helm/loki/values-final-work.yaml"), "Loki values")
    tempo = mapping(helm_values(repo_root / "helm/tempo/values-final-work.yaml"), "Tempo values")
    grafana = mapping(stack.get("grafana"), "grafana")
    prometheus = mapping(stack.get("prometheus"), "prometheus")
    spec = mapping(prometheus.get("prometheusSpec"), "prometheus.prometheusSpec")
    storage_spec = mapping(spec.get("storageSpec"), "prometheus.prometheusSpec.storageSpec")
    template = mapping(storage_spec.get("volumeClaimTemplate"), "prometheus volumeClaimTemplate")
    template_spec = mapping(template.get("spec"), "prometheus volumeClaimTemplate.spec")
    single = mapping(loki.get("singleBinary"), "loki.singleBinary")
    lp = mapping(single.get("persistence"), "loki.singleBinary.persistence")
    tp = mapping(tempo.get("persistence"), "tempo.persistence")
    grafana_persistence = mapping(grafana.get("persistence"), "grafana.persistence")
    if not grafana_persistence.get("enabled") or grafana_persistence.get("storageClassName") != "hcloud-volumes":
        fail("Grafana persistence must be enabled with hcloud-volumes")
    if template_spec.get("storageClassName") != "hcloud-volumes":
        fail("Prometheus persistence must use hcloud-volumes")
    if not lp.get("enabled") or lp.get("storageClass") != "hcloud-volumes":
        fail("Loki persistence must be enabled with hcloud-volumes")
    if not tp.get("enabled") or tp.get("storageClassName") != "hcloud-volumes":
        fail("Tempo persistence must be enabled with hcloud-volumes")
    if spec.get("replicas") != 2 or single.get("replicas") != 1 or tempo.get("replicas") != 1:
        fail("monitoring replicas must be Prometheus=2, Loki=1, Tempo=1")
    return {
        "grafana": quantity(grafana_persistence.get("size"), "Grafana persistence.size"),
        "loki": quantity(lp.get("size"), "Loki singleBinary.persistence.size"),
        "tempo": quantity(tp.get("size"), "Tempo persistence.size"),
        "prometheus-0": quantity(mapping(mapping(template_spec.get("resources"), "Prometheus resources").get("requests"), "Prometheus resource requests").get("storage"), "Prometheus storage"),
        "prometheus-1": quantity(mapping(mapping(template_spec.get("resources"), "Prometheus resources").get("requests"), "Prometheus resource requests").get("storage"), "Prometheus storage"),
    }


def expected(registry, repo_root=REPO_ROOT):
    claims = registry.get("expectedClaims")
    if registry.get("namespace") != "monitoring" or registry.get("storageClass") != "hcloud-volumes":
        fail("registry namespace/storageClass is not the monitoring contract")
    if not isinstance(claims, list) or len(claims) != 5:
        fail("registry must define exactly five expected claims")
    capacities = storage_contract(repo_root)
    result = {}
    roles = []
    for item in claims:
        if not isinstance(item, dict):
            fail("registry expectedClaims entries must be mappings")
        claim = item.get("claim")
        role = item.get("role")
        roles.append(role)
        if not claim or claim in result or role not in capacities:
            fail("registry contains an invalid or duplicate expected claim")
        result[claim] = {**item, "sizeGi": capacities[role]}
    if len(set(roles)) != len(capacities) or set(roles) != set(capacities):
        fail("registry must contain exactly one claim for every configured monitoring role")
    return result


def label(labels, keys):
    values = [str(labels[key]) for key in keys if key in labels and labels[key] not in (None, "")]
    if len(set(values)) > 1:
        fail(f"conflicting CSI labels for {keys[0]}")
    return values[0] if values else None


def location(volume):
    value = volume.get("location")
    return value.get("name") if isinstance(value, dict) else value


def detached(volume):
    # hcloud volume JSON exposes server=null for an unattached volume. Do not
    # infer detached state when the authoritative field is absent.
    return "server" in volume and volume["server"] is None


def claim_matches(pvc_name, claims):
    matches = []
    for claim in claims:
        suffix = claim[-63:] if len(claim) > 63 else claim
        if pvc_name == claim or pvc_name == suffix:
            matches.append(claim)
    return matches


def volume_identity(volume, claims, namespace):
    labels = volume.get("labels") or {}
    pvc_name = label(labels, PVC_NAME_KEYS)
    pvc_namespace = label(labels, PVC_NAMESPACE_KEYS)
    created_by = label(labels, CREATED_BY_KEYS)
    role = labels.get(ROLE_LABEL)
    # created-by/managed-by alone is not a monitoring identity. This is
    # important because CSI labels many unrelated volumes.
    monitoring_signal = pvc_name is not None or pvc_namespace is not None
    if not monitoring_signal:
        return None
    if pvc_name is None or pvc_namespace != namespace:
        return None
    matches = claim_matches(pvc_name, claims)
    if len(matches) != 1:
        fail(f"volume {volume.get('id')} PVC label is ambiguous or unknown")
    claim = matches[0]
    if role is not None and role != claims[claim]["role"]:
        fail(f"volume {volume.get('id')} custom role label conflicts with PVC label")
    if created_by is not None and "csi" not in created_by.lower() and "hetzner" not in created_by.lower():
        fail(f"volume {volume.get('id')} is not marked as CSI-created")
    return claim


def validate_volumes(registry, volumes, require_detached=True, repo_root=REPO_ROOT):
    claims = expected(registry, repo_root)
    legacy = {str(value) for value in registry.get("legacyVolumeIds", [])}
    if len(legacy) != 5:
        fail("registry must list exactly five legacy volume IDs")
    candidates = {claim: [] for claim in claims}
    for volume in volumes:
        volume_id = str(volume.get("id"))
        claim = volume_identity(volume, claims, registry["namespace"])
        if volume_id in legacy and claim is None:
            fail(f"known legacy volume {volume_id} has no authoritative identity")
        if claim is None:
            continue
        if location(volume) != registry["location"]:
            fail(f"volume {volume_id} location is not {registry['location']}")
        item = claims[claim]
        if int(volume.get("size", -1)) != item["sizeGi"]:
            fail(f"volume {volume_id} size does not match {claim}")
        candidates[claim].append(volume)
    selected = {}
    for claim, items in candidates.items():
        if not items:
            continue
        legacy_items = [item for item in items if str(item.get("id")) in legacy]
        if len(legacy_items) == 1:
            selected[claim] = legacy_items[0]
            continue
        if len(legacy_items) > 1:
            fail(f"multiple legacy volumes identify {claim}")
        tagged = [item for item in items if (item.get("labels") or {}).get(ROLE_LABEL) == claims[claim]["role"]]
        if len(tagged) == 1:
            selected[claim] = tagged[0]
            continue
        if len(tagged) > 1:
            fail(f"multiple tagged replacement volumes identify {claim}")
        if len(items) == 1:
            selected[claim] = items[0]
            continue
        fail(f"multiple untagged replacement volumes identify {claim}")
    if require_detached:
        # Validate attachment only after selection. An attached duplicate that
        # loses to a legacy volume must not abort recovery.
        for claim, volume in selected.items():
            if not detached(volume):
                volume["_selected_attached"] = True
    return selected


def pv_manifest(registry, selected, repo_root=REPO_ROOT):
    claims = expected(registry, repo_root)
    documents = []
    for claim, volume in sorted(selected.items()):
        item = claims[claim]
        role = item["role"]
        documents.append({
            "apiVersion": "v1", "kind": "PersistentVolume",
            "metadata": {"name": f"monitoring-{role}-pv", "labels": {MANAGED_LABEL: "true", ROLE_LABEL: role},
                         "annotations": {"cluster-infra/selected-attached": "true"} if volume.get("_selected_attached") else {}},
            "spec": {
                "capacity": {"storage": f"{item['sizeGi']}Gi"},
                "accessModes": ["ReadWriteOnce"],
                "persistentVolumeReclaimPolicy": "Retain",
                "storageClassName": registry["storageClass"], "volumeMode": "Filesystem",
                "claimRef": {"namespace": registry["namespace"], "name": claim},
                "csi": {"driver": CSI, "volumeHandle": str(volume["id"]), "fsType": "ext4"},
                "nodeAffinity": {"required": {"nodeSelectorTerms": [{"matchExpressions": [{
                    "key": "topology.kubernetes.io/zone", "operator": "In", "values": [registry["location"]]
                }]}]}},
            },
        })
    return documents


def kubectl_json(resource):
    if not shutil.which("kubectl"):
        fail("kubectl is required")
    result = subprocess.run(["kubectl", "get", resource, "-A", "-o", "json"], capture_output=True, text=True)
    if result.returncode:
        fail(f"kubectl get {resource} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def plan_documents(documents, existing_items, existing_claim_items):
    existing = {item["metadata"]["name"]: item for item in existing_items}
    existing_claims = {
        (item["metadata"].get("namespace"), item["metadata"]["name"]): item
        for item in existing_claim_items
    }
    by_handle = {}
    for item in existing.values():
        handle = item.get("spec", {}).get("csi", {}).get("volumeHandle")
        if handle:
            if handle in by_handle and by_handle[handle]["metadata"]["name"] != item["metadata"]["name"]:
                fail(f"multiple PVs already reference CSI volumeHandle {handle}")
            by_handle[handle] = item
    to_apply = []
    for document in documents:
        desired_spec = document["spec"]
        desired_handle = str(desired_spec["csi"]["volumeHandle"])
        desired_name = document["metadata"]["name"]
        current = existing.get(document["metadata"]["name"])
        if current:
            current_spec = current.get("spec", {})
            if str(current_spec.get("csi", {}).get("volumeHandle")) != desired_handle:
                fail(f"existing PV {document['metadata']['name']} has a conflicting volumeHandle")
            if current_spec.get("csi", {}).get("driver") != CSI:
                fail(f"existing PV {document['metadata']['name']} has a conflicting CSI driver")
            current_claim_ref = current_spec.get("claimRef", {})
            if {key: current_claim_ref.get(key) for key in ("namespace", "name")} != desired_spec["claimRef"]:
                fail(f"existing PV {document['metadata']['name']} has a conflicting claimRef")
            if current_spec.get("capacity", {}).get("storage") != desired_spec["capacity"]["storage"]:
                fail(f"existing PV {document['metadata']['name']} has a conflicting capacity")
            if current_spec.get("storageClassName") != desired_spec["storageClassName"]:
                fail(f"existing PV {document['metadata']['name']} has a conflicting storage class")
            if current_spec.get("csi", {}).get("fsType") != desired_spec["csi"]["fsType"]:
                fail(f"existing PV {document['metadata']['name']} has a conflicting fsType")
            if current_spec.get("nodeAffinity") != desired_spec.get("nodeAffinity"):
                fail(f"existing PV {document['metadata']['name']} has conflicting node affinity")
        claim_ref = document["spec"]["claimRef"]
        current_claim = existing_claims.get((claim_ref["namespace"], claim_ref["name"]))
        if current_claim and current_claim.get("status", {}).get("phase") == "Bound":
            bound_pv = existing.get(current_claim.get("spec", {}).get("volumeName"), {})
            bound_handle = bound_pv.get("spec", {}).get("csi", {}).get("volumeHandle")
            if str(bound_handle) != desired_handle:
                fail(f"PVC {claim_ref['namespace']}/{claim_ref['name']} is already bound to another volume")
            if current_claim.get("spec", {}).get("volumeName") != desired_name:
                # The claim already owns the desired Hetzner handle through a
                # different PV. Creating a second PV for that handle is unsafe.
                continue
            continue
        elif document["metadata"].get("annotations", {}).get("cluster-infra/selected-attached") == "true":
            if not current_claim or current_claim.get("status", {}).get("phase") != "Bound":
                fail(f"selected volume for {claim_ref['name']} is attached but not already bound")
        if current_claim and current_claim.get("spec", {}).get("volumeName") not in (None, "", desired_name):
            fail(f"PVC {claim_ref['namespace']}/{claim_ref['name']} has a conflicting volumeName")
        other = by_handle.get(desired_handle)
        if other and other["metadata"]["name"] != desired_name:
            fail(f"CSI volumeHandle {desired_handle} is already referenced by another PV")
        if not current:
            to_apply.append(document)
    return to_apply


def apply_documents(documents):
    existing_items = kubectl_json("pv").get("items", [])
    existing_claim_items = kubectl_json("pvc").get("items", [])
    documents = plan_documents(documents, existing_items, existing_claim_items)
    if not documents:
        return
    payload = "---\n".join(json.dumps(item) for item in documents)
    result = subprocess.run(["kubectl", "apply", "-f", "-"], input=payload, text=True, capture_output=True)
    if result.returncode:
        fail(f"kubectl apply failed: {result.stderr.strip()}")


def verify_bindings(registry, selected, pvcs, pvs):
    claims = expected(registry)
    if set(selected) != set(claims):
        fail("post-recovery requires one selected volume for every expected claim")
    by_pv = {item["metadata"]["name"]: item for item in pvs}
    by_claim = {(item["metadata"].get("namespace"), item["metadata"]["name"]): item for item in pvcs}
    bound = {}
    for claim, volume in selected.items():
        pvc = by_claim.get((registry["namespace"], claim))
        if not pvc or pvc.get("status", {}).get("phase") != "Bound":
            fail(f"PVC {registry['namespace']}/{claim} is not Bound")
        assert pvc is not None
        pv = by_pv.get(pvc.get("spec", {}).get("volumeName"), {})
        handle = pv.get("spec", {}).get("csi", {}).get("volumeHandle")
        if str(handle) != str(volume["id"]):
            fail(f"PVC {claim} is bound to an unexpected CSI volume")
        bound[claim] = pv
    return bound


def post_verify_and_tag(registry, selected):
    claims = expected(registry)
    bound = verify_bindings(registry, selected, kubectl_json("pvc").get("items", []), kubectl_json("pv").get("items", []))
    for claim, pv in bound.items():
        if pv.get("spec", {}).get("persistentVolumeReclaimPolicy") != "Retain":
            patch = subprocess.run([
                "kubectl", "patch", "pv", pv["metadata"]["name"], "--type=merge",
                "-p", '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}',
            ], capture_output=True, text=True)
            if patch.returncode:
                fail(f"could not protect PV for {claim}: {patch.stderr.strip()}")
    protected = {item["metadata"]["name"]: item for item in kubectl_json("pv").get("items", [])}
    for claim, pv in bound.items():
        if protected.get(pv["metadata"]["name"], {}).get("spec", {}).get("persistentVolumeReclaimPolicy") != "Retain":
            fail(f"PV reclaim policy verification failed for {claim}")
    if not shutil.which("hcloud"):
        fail("hcloud is required for post-recovery label registration")
    for claim, volume in selected.items():
        role = claims[claim]["role"]
        result = subprocess.run([
            "hcloud", "volume", "add-label", str(volume["id"]), f"{ROLE_LABEL}={role}"
        ], capture_output=True, text=True)
        if result.returncode:
            fail(f"could not register volume {volume['id']}: {result.stderr.strip()}")
    fresh = subprocess.run(["hcloud", "volume", "list", "-o", "json"], capture_output=True, text=True)
    if fresh.returncode:
        fail(f"could not refresh volume list after registration: {fresh.stderr.strip()}")
    fresh_volumes = json.loads(fresh.stdout)
    refreshed = validate_volumes(registry, fresh_volumes, require_detached=False)
    for claim, volume in selected.items():
        if str(refreshed.get(claim, {}).get("id")) != str(volume["id"]):
            fail(f"volume registration verification failed for {claim}")
        matching = next(item for item in fresh_volumes if str(item.get("id")) == str(volume["id"]))
        if (matching.get("labels") or {}).get(ROLE_LABEL) != claims[claim]["role"]:
            fail(f"volume role label verification failed for {claim}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", type=Path, default=REGISTRY)
    parser.add_argument("--volumes-json", type=Path)
    parser.add_argument("--print-manifest", action="store_true")
    parser.add_argument("--post", action="store_true")
    args = parser.parse_args()
    try:
        registry = load_json(args.registry)
        if not args.volumes_json:
            fail("authoritative volume list is required")
        selected = validate_volumes(registry, load_json(args.volumes_json), require_detached=not args.post)
        if args.post:
            post_verify_and_tag(registry, selected)
            print("monitoring PVC recovery post-verification passed")
            return 0
        documents = pv_manifest(registry, selected)
        if args.print_manifest:
            for document in documents:
                print(json.dumps(document, indent=2))
        elif documents:
            apply_documents(documents)
        else:
            print("no identified legacy volumes; dynamic provisioning remains enabled")
        return 0
    except (OSError, ValueError, KeyError, TypeError, RecoveryError) as error:
        print(f"monitoring volume recovery refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
