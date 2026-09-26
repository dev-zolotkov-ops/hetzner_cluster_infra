*Ручное монтирование существующих томов 

Если релиз уже создал новые PVC и тома, вручную для каждого PVC нужно освободить его имя и создать привязку к старому Hetzner ID. Пример ниже для Grafana; для двух Prometheus, Loki и Tempo действия те же.

Сопоставь старые ID с PVC по pvc-name/pvc-namespace, проверь размер и что старый том отсоединён. Сохрани данные и манифесты новых PVC/PV перед переключением.

hcloud volume list -o json |
  jq -r '.[] | [.id, .size, .location.name, .labels["pvc-name"], .labels["pvc-namespace"]] | @tsv'

Останови использующие PVC приложения, включая Prometheus через его оператор, и дождись удаления Pod’ов:

kubectl -n monitoring scale deployment/kube-prometheus-stack-grafana statefulset/loki statefulset/tempo --replicas=0
kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus --type=merge -p '{"spec":{"replicas":0}}'
kubectl -n monitoring get pods

Сохрани новый том, прежде чем удалять его PVC. Для Grafana:

CLAIM=kube-prometheus-stack-grafana
NEW_PV=$(kubectl -n monitoring get pvc "$CLAIM" -o jsonpath='{.spec.volumeName}')
kubectl -n monitoring get pvc "$CLAIM" -o yaml > grafana-pvc-before.yaml
kubectl get pv "$NEW_PV" -o yaml > grafana-new-pv-before.yaml
kubectl patch pv "$NEW_PV" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

С Retain удаление PVC оставит новый Hetzner-том на месте. Проверь, что патч применился, до удаления PVC.

Удали новый PVC после остановки Pod’ов:

kubectl -n monitoring delete pvc "$CLAIM"

Не удаляй finalizer вручную: если PVC остаётся в Terminating, его ещё использует Pod.

Создай PV для старого тома. Подставь проверенный OLD_ID; размер должен соответствовать старому тому и запросу PVC:

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
Создай PVC с прежним именем, тем же StorageClass и запросом размера, указав spec.volumeName: restore-grafana. За основу возьми сохранённый grafana-pvc-before.yaml: убери status и служебные поля Kubernetes (uid, resourceVersion, creationTimestamp, managedFields, finalizers), сохрани Helm-аннотации владельца. claimRef на PV и volumeName на PVC задают конкретную пару.

Проверь Bound и Hetzner ID:

kubectl -n monitoring get pvc "$CLAIM"
kubectl get pv restore-grafana -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'

После переключения всех пяти PVC верни реплики Grafana, Loki, Tempo и Prometheus и проверь данные в приложениях. Старые новосозданные тома пока оставь с Retain: удалять их стоит только после проверки восстановления.