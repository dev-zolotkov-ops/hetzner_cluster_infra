#!/usr/bin/env bash
set -Eeuo pipefail

readonly WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-120}"
readonly POLL_SECONDS="${POLL_SECONDS:-5}"
readonly CCM_LABEL="app.kubernetes.io/name=hcloud-cloud-controller-manager"

for command in kubectl hcloud terraform jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'error: required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

services_file="$(mktemp)"
service_refs_file="$(mktemp)"
trap 'rm -f "$services_file" "$service_refs_file"' EXIT

printf 'Discovering Kubernetes LoadBalancer Services...\n'
kubectl get services --all-namespaces -o json >"$services_file"

# Keep the Service identity and any allocated addresses before deletion. CCM
# normally labels its Load Balancers with the Service name and UID; addresses
# are retained as a fallback for older CCM versions and pending Services.
jq -c '
  .items[]
  | select(.spec.type == "LoadBalancer")
  | {
      namespace: .metadata.namespace,
      name: .metadata.name,
      uid: .metadata.uid,
      service_name: (.metadata.namespace + "/" + .metadata.name),
      addresses: [
        ((.status.loadBalancer.ingress // []) | .[] | (.ip // .hostname)),
        ((.spec.externalIPs // []) | .[])
      ] | map(select(type == "string" and length > 0))
    }
' "$services_file" >"$service_refs_file"

service_count="$(jq 'length' < <(jq -s '.' "$service_refs_file"))"
if [[ "$service_count" == "0" ]]; then
  printf 'No Kubernetes LoadBalancer Services found.\n'
else
  printf 'Deleting %s Kubernetes LoadBalancer Service(s) so CCM can clean up...\n' "$service_count"
  while IFS=$'\t' read -r namespace name; do
    kubectl delete service "$name" --namespace "$namespace" --ignore-not-found --wait=false
  done < <(jq -r '[.namespace, .name] | @tsv' "$service_refs_file")
fi

# Wait for Kubernetes deletion, but do not let a finalizer block cleanup
# indefinitely. CCM remains running during this phase to perform cleanup.
deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  pending=0
  while IFS=$'\t' read -r namespace name; do
    if kubectl get service "$name" --namespace "$namespace" >/dev/null 2>&1; then
      pending=$((pending + 1))
    fi
  done < <(jq -r '[.namespace, .name] | @tsv' "$service_refs_file")
  if (( pending == 0 )); then
    break
  fi
  printf 'Waiting for %s Service deletion(s) to complete...\n' "$pending"
  sleep "$POLL_SECONDS"
done

# Stop CCM only after it had the bounded opportunity to remove its LBs. This
# prevents it from recreating an LB while the direct fallback is in progress.
while IFS=$'\t' read -r namespace name; do
  printf 'Scaling down hcloud CCM deployment %s/%s...\n' "$namespace" "$name"
  kubectl scale deployment "$name" --namespace "$namespace" --replicas=0
done < <(kubectl get deployments --all-namespaces -l "$CCM_LABEL" -o json |
  jq -r '.items[] | [.metadata.namespace, .metadata.name] | @tsv')

lb_json() {
  hcloud load-balancer list -o json
}

# hcloud CLI versions expose the address either as the nested hcloud-go
# public_net.ipv4.ip field or as the older public_ipv4 field.
lb_matches() {
  jq -c --slurpfile services "$service_refs_file" '
    .[] as $lb
    | ($lb.labels // {}) as $labels
    | [
        ($lb.public_net.ipv4.ip // $lb.public_ipv4 // ""),
        ($lb.public_net.ipv6.ip // $lb.public_ipv6 // "")
      ] as $ips
    | select(any($services[];
        (($labels["kubernetes.io/service-uid"] // "") == .uid)
        or (($labels["kubernetes.io/service-name"] // "") == .service_name)
       or any(.addresses[]?; . as $address | ($ips | index($address)) != null)
      ))
    | $lb
  '
}

deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  remaining="$(lb_json | lb_matches | jq -s 'length')"
  if [[ "$remaining" == "0" ]]; then
    printf 'Cluster Load Balancers are gone after CCM cleanup.\n'
    break
  fi
  printf 'Waiting for CCM to remove %s cluster Load Balancer(s)...\n' "$remaining"
  sleep "$POLL_SECONDS"
done

fallback_ids="$(lb_json | lb_matches | jq -r '.id')"
if [[ -n "$fallback_ids" ]]; then
  while IFS= read -r lb_id; do
    [[ -n "$lb_id" ]] || continue
    printf 'Deleting remaining cluster Load Balancer %s via hcloud...\n' "$lb_id"
    hcloud load-balancer delete "$lb_id"
  done <<<"$fallback_ids"
else
  printf 'No remaining cluster-owned Load Balancers require hcloud fallback.\n'
fi

printf 'Running terraform destroy...\n'
terraform destroy "$@"
