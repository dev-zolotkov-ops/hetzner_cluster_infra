# Восстановление хранилищ мониторинга

`install.sh` запускает `storage/recover_monitoring_volumes.py` сразу после
установки CSI и до Helm-релизов мониторинга. Шаг идемпотентен и работает с
fail-closed политикой:

- На пустом кластере без найденных старых volume не создаётся PV, поэтому CSI
  продолжает динамическое provision-ирование.
- Volume принимается только при совпадении CSI-меток `pvc-name` и
  `pvc-namespace` с одним из пяти ожидаемых claims. Для длинного имени
  допускается левая обрезка до последних 63 символов.
- При наличии старого и нового volume для одного claim выбирается legacy ID.
  Если его нет, нужен ровно один role-tagged кандидат или ровно один другой
  кандидат. Неоднозначность, отсутствие identity у известного legacy ID,
  неверный размер/локация, подключённый выбранный legacy volume и конфликт
  Kubernetes binding останавливают bootstrap.
- Восстановленный PV использует CSI `csi.hetzner.cloud`, StorageClass
  `hcloud-volumes`, RWO, `ext4`, `Retain`, zone affinity и точный `claimRef`.

Реестр находится в `storage/monitoring-volume-registry.json`: в нём указаны
пять claims и legacy IDs. Размеры в реестре не дублируются. Необязательная
метка `cluster-infra-pvc-id=<role>` проверяется относительно CSI-меток и сама
по себе identity не является.

Размеры, включённость persistence, StorageClass и replica count читаются при
каждом запуске из vendored Helm values:

- `helm/kube-prometheus-stack/values.yaml` для Grafana и Prometheus;
- `helm/loki/values-final-work.yaml` для Loki;
- `helm/tempo/values-final-work.yaml` для Tempo.

Локация `fsn1` задаётся в реестре, а не в Helm values. Скрипт требует Python 3
и PyYAML и останавливается при неверной структуре YAML, отключённом persistence,
неподходящем StorageClass, неверных replica count или неположительном Gi
размере.

Офлайн-проверка манифеста:

```bash
python3 storage/recover_monitoring_volumes.py \
  --volumes-json /path/to/verified-hcloud-volume-list.json --print-manifest
```

JSON должен содержать только необходимые поля списка volume, например `id`,
`size`, `location` и `labels`. Не сохраняйте token или API-ответы с секретами.

После установки monitoring `install.sh` получает новый authoritative volume
list, проверяет все пять PVC и CSI handles, устанавливает `Retain` для bound
PV, добавляет короткую role-метку только выбранным volume и повторно проверяет
метки. Чужие и orphan volume не изменяются. Нельзя сопоставлять replacement
только по размеру или возрасту.

Ручная post-проверка:

```bash
hcloud volume list -o json > /tmp/volumes.json
python3 storage/recover_monitoring_volumes.py --post --volumes-json /tmp/volumes.json
```

Режим `--print-manifest` ничего не изменяет. Post-режим после Kubernetes
проверок использует `hcloud volume add-label <id>
cluster-infra-pvc-id=<role>` и проверяет результат свежим списком volume.
