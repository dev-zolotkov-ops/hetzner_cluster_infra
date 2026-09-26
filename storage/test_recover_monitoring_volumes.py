#!/usr/bin/env python3
import importlib.util
import unittest

spec = importlib.util.spec_from_file_location("recovery", "storage/recover_monitoring_volumes.py")
assert spec is not None and spec.loader is not None
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)
REGISTRY = recovery.load_json(recovery.REGISTRY)


def volume(number, claim_name, size, namespace="monitoring", role=None, server=None):
    labels = {"pvc-name": claim_name, "pvc-namespace": namespace, "created-by": "hcloud-csi"}
    if role:
        labels[recovery.ROLE_LABEL] = role
    return {"id": number, "size": size, "location": {"name": "fsn1"}, "server": server, "labels": labels}


class RecoveryTests(unittest.TestCase):
    def all_claim_volumes(self, old=True):
        claims = recovery.expected(REGISTRY)
        ids = REGISTRY["legacyVolumeIds"] if old else [200001, 200002, 200003, 200004, 200005]
        result = []
        for volume_id, (claim, item) in zip(ids, claims.items()):
            pvc_name = claim[-63:] if claim.startswith("prometheus-") else claim
            result.append(volume(volume_id, pvc_name, item["sizeGi"], role=None if old else item["role"]))
        return result

    def test_all_old_volumes_win_over_new_duplicates_and_post_binds(self):
        claims = recovery.expected(REGISTRY)
        old = self.all_claim_volumes(old=True)
        new = self.all_claim_volumes(old=False)
        selected = recovery.validate_volumes(REGISTRY, list(reversed(new + old)))
        self.assertEqual({claim: selected[claim]["id"] for claim in claims}, {
            claim: volume_id for claim, volume_id in zip(claims, REGISTRY["legacyVolumeIds"])
        })
        manifests = recovery.pv_manifest(REGISTRY, selected)
        self.assertEqual(len(manifests), 5)
        self.assertEqual({doc["spec"]["claimRef"]["name"]: doc["spec"]["csi"]["volumeHandle"] for doc in manifests}, {
            claim: str(volume_id) for claim, volume_id in zip(claims, REGISTRY["legacyVolumeIds"])
        })
        pvcs = []
        pvs = []
        for index, (claim, volume_id) in enumerate(zip(claims, REGISTRY["legacyVolumeIds"])):
            pv_name = f"pv-{index}"
            pvcs.append({"metadata": {"namespace": "monitoring", "name": claim}, "status": {"phase": "Bound"}, "spec": {"volumeName": pv_name}})
            pvs.append({"metadata": {"name": pv_name}, "spec": {"csi": {"volumeHandle": str(volume_id)}}})
        bound = recovery.verify_bindings(REGISTRY, selected, pvcs, pvs)
        self.assertEqual(len(bound), 5)

    def test_first_boot_new_volumes_are_post_candidates_and_empty_pre_is_empty(self):
        self.assertEqual(recovery.pv_manifest(REGISTRY, recovery.validate_volumes(REGISTRY, [])), [])
        selected = recovery.validate_volumes(REGISTRY, self.all_claim_volumes(old=False))
        self.assertEqual({volume["id"] for volume in selected.values()}, {200001, 200002, 200003, 200004, 200005})

    def test_bare_cluster_has_no_static_manifest(self):
        self.assertEqual(recovery.validate_volumes(REGISTRY, []), {})

    def test_all_five_labels_map_without_size_inference(self):
        claims = recovery.expected(REGISTRY)
        volumes = [volume(number, claim, item["sizeGi"]) for number, (claim, item) in zip(REGISTRY["legacyVolumeIds"], claims.items())]
        selected = recovery.validate_volumes(REGISTRY, volumes)
        self.assertEqual(set(selected), set(claims))

    def test_left_truncated_long_claim_matches_only_suffix(self):
        claim = next(name for name in recovery.expected(REGISTRY) if name.startswith("prometheus-"))
        truncated = claim[-63:]
        selected = recovery.validate_volumes(REGISTRY, [volume(106953876, truncated, 30)])
        self.assertEqual(selected[claim]["id"], 106953876)

    def test_known_missing_identity_fails_closed(self):
        item = volume(106953874, "", 10)
        item["labels"] = {}
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_volumes(REGISTRY, [item])

    def test_legacy_wins_over_new_duplicate(self):
        claim = "kube-prometheus-stack-grafana"
        replacement = volume(9001, claim, 10, role="grafana")
        selected = recovery.validate_volumes(REGISTRY, [replacement, volume(106953874, claim, 10)])
        self.assertEqual(selected[claim]["id"], 106953874)

    def test_unique_tagged_replacement_wins_when_legacy_absent(self):
        claim = "kube-prometheus-stack-grafana"
        selected = recovery.validate_volumes(REGISTRY, [volume(9001, claim, 10, role="grafana")])
        self.assertEqual(selected[claim]["id"], 9001)

    def test_ambiguous_replacements_fail_closed(self):
        claim = "kube-prometheus-stack-grafana"
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_volumes(REGISTRY, [volume(9001, claim, 10), volume(9002, claim, 10)])

    def test_foreign_namespace_and_created_by_only_are_ignored(self):
        foreign = volume(9001, "kube-prometheus-stack-grafana", 10, namespace="other")
        foreign["id"] = 9002
        created_only = {"id": 9003, "size": 10, "location": {"name": "fsn1"}, "server": None, "labels": {"created-by": "hcloud-csi"}}
        self.assertEqual(recovery.validate_volumes(REGISTRY, [foreign, created_only]), {})

    def test_wrong_namespace_size_location_or_attachment_fails(self):
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_volumes(REGISTRY, [volume(106953874, "kube-prometheus-stack-grafana", 10, namespace="default")])
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_volumes(REGISTRY, [volume(106953874, "kube-prometheus-stack-grafana", 30)])
        attached = volume(106953874, "kube-prometheus-stack-grafana", 10, server={"id": 1})
        selected = recovery.validate_volumes(REGISTRY, [attached])
        manifest = recovery.pv_manifest(REGISTRY, selected)[0]
        self.assertEqual(manifest["metadata"]["annotations"]["cluster-infra/selected-attached"], "true")

    def test_attached_new_duplicate_does_not_block_legacy_selection(self):
        claim = "kube-prometheus-stack-grafana"
        selected = recovery.validate_volumes(REGISTRY, [
            volume(9001, claim, 10, server={"id": 2}),
            volume(106953874, claim, 10),
        ])
        self.assertEqual(selected[claim]["id"], 106953874)

    def test_manifest_has_exact_claim_ref_and_handle(self):
        selected = recovery.validate_volumes(REGISTRY, [volume(106953874, "kube-prometheus-stack-grafana", 10)])
        manifest = recovery.pv_manifest(REGISTRY, selected)[0]
        self.assertEqual(manifest["spec"]["claimRef"], {"namespace": "monitoring", "name": "kube-prometheus-stack-grafana"})
        self.assertEqual(manifest["spec"]["csi"]["volumeHandle"], "106953874")
        self.assertEqual(manifest["spec"]["persistentVolumeReclaimPolicy"], "Retain")

    def test_post_binding_handle_mismatch_fails(self):
        claim = "kube-prometheus-stack-grafana"
        selected = {claim: volume(106953874, claim, 10)}
        pvc = {"metadata": {"namespace": "monitoring", "name": claim}, "status": {"phase": "Bound"}, "spec": {"volumeName": "pv"}}
        pv = {"metadata": {"name": "pv"}, "spec": {"csi": {"volumeHandle": "wrong"}, "persistentVolumeReclaimPolicy": "Retain"}}
        with self.assertRaises(recovery.RecoveryError):
            recovery.verify_bindings(REGISTRY, selected, [pvc], [pv])

    def test_bound_existing_dynamic_pv_skips_duplicate_static_pv(self):
        claim = "kube-prometheus-stack-grafana"
        selected = recovery.validate_volumes(REGISTRY, [volume(106953874, claim, 10)])
        desired = recovery.pv_manifest(REGISTRY, selected)
        existing_pv = {"metadata": {"name": "dynamic-pv"}, "spec": {
            "csi": {"driver": recovery.CSI, "volumeHandle": "106953874", "fsType": "ext4"},
            "claimRef": {"namespace": "monitoring", "name": claim}, "capacity": {"storage": "10Gi"},
            "storageClassName": "hcloud-volumes", "nodeAffinity": desired[0]["spec"]["nodeAffinity"],
        }}
        existing_pvc = {"metadata": {"namespace": "monitoring", "name": claim}, "status": {"phase": "Bound"}, "spec": {"volumeName": "dynamic-pv"}}
        self.assertEqual(recovery.plan_documents(desired, [existing_pv], [existing_pvc]), [])

    def test_second_existing_pv_with_same_handle_fails(self):
        claim = "kube-prometheus-stack-grafana"
        selected = recovery.validate_volumes(REGISTRY, [volume(106953874, claim, 10)])
        desired = recovery.pv_manifest(REGISTRY, selected)
        first = {"metadata": {"name": "other-pv"}, "spec": {"csi": {"driver": recovery.CSI, "volumeHandle": "106953874"}}}
        with self.assertRaises(recovery.RecoveryError):
            recovery.plan_documents(desired, [first], [])


if __name__ == "__main__":
    unittest.main()
