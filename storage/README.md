*Manually mounting existing volumes

If the release has already created new PVCs and volumes, manually free the name of each PVC and bind it to the old Hetzner ID. The example below is for Grafana; use the same procedure for the two Prometheus instances, Loki, and Tempo.

Map the old IDs to PVCs using pvc-name/pvc-namespace, verify the size, and confirm that the old volume is detached. Save the data and manifests of the new PVCs/PVs before switching.

hcloud volume list -o json |
  jq -r '.[] | [.id, .size, .location.name, .labels["pvc-name"], .labels["pvc-namespace"]] | @tsv'

Stop the applications using the PVCs, including Prometheus through its operator, and wait for the Pods to be deleted:

kubectl -n monitoring scale deployment/kube-prometheus-stack-grafana statefulset/loki statefulset/tempo --replicas=0
kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus --type=merge -p '{"spec":{"replicas":0}}'
kubectl -n monitoring get pods

Preserve the new volume before deleting its PVC. For Grafana:

CLAIM=kube-prometheus-stack-grafana
NEW_PV=$(kubectl -n monitoring get pvc "$CLAIM" -o jsonpath='{.spec.volumeName}')
kubectl -n monitoring get pvc "$CLAIM" -o yaml > grafana-pvc-before.yaml
kubectl get pv "$NEW_PV" -o yaml > grafana-new-pv-before.yaml
kubectl patch pv "$NEW_PV" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

With Retain, deleting the PVC will leave the new Hetzner volume in place. Verify that the patch was applied before deleting the PVC.

Delete the new PVC after the Pods have stopped:

kubectl -n monitoring delete pvc "$CLAIM"

Do not remove the finalizer manually: if the PVC remains in Terminating, a Pod is still using it.

Create a PV for the old volume. Substitute the verified OLD_ID; the size must match the old volume and the PVC request:

apiVersion: v1
kind: PersistentVolume
metadata:
  name: restore-grafana
spec:
  capacity:
    storage: 10Gi
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: hcloud-volumes
  persistentVolumeReclaimPolicy: Retain
  claimRef:
    namespace: monitoring
    name: kube-prometheus-stack-grafana
  csi:
    driver: csi.hetzner.cloud
    volumeHandle: "<OLD_ID>"
    fsType: ext4
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values: [fsn1]
Create a PVC with the previous name, the same StorageClass, and the same size request, specifying spec.volumeName: restore-grafana. Use the saved grafana-pvc-before.yaml as the basis: remove status and Kubernetes-managed fields (uid, resourceVersion, creationTimestamp, managedFields, finalizers), while preserving the Helm owner annotations. claimRef on the PV and volumeName on the PVC define the specific pair.

Verify Bound and the Hetzner ID:

kubectl -n monitoring get pvc "$CLAIM"
kubectl get pv restore-grafana -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'

After switching all five PVCs, restore the replicas for Grafana, Loki, Tempo, and Prometheus, and verify the data in the applications. Leave the newly created old volumes with Retain for now: delete them only after verifying the recovery.
