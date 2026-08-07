#!/usr/bin/env bash
set -euo pipefail

LAB_SELECTOR="app.kubernetes.io/part-of=istio-mtls-lab"

all_pods_lack_sidecars() {
  local pod state deleting containers
  for pod in $(kubectl get pods -n lab-mesh -l app.kubernetes.io/part-of=istio-mtls-lab -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    state="$(kubectl get pod "${pod}" -n lab-mesh -o jsonpath='{.metadata.deletionTimestamp}{"|"}{.spec.containers[*].name}' 2>/dev/null || true)"
    [[ -z "${state}" ]] && continue
    deleting="${state%%|*}"
    containers="${state#*|}"
    [[ -n "${deleting}" ]] && continue
    if grep -qw istio-proxy <<<"${containers}"; then
      echo "ERROR: pod ${pod} still has istio-proxy." >&2
      return 1
    fi
  done
}

wait_for_lab_rollouts() {
  local deployment
  for deployment in $(kubectl get deployment -n lab-mesh -l "${LAB_SELECTOR}" -o name); do
    kubectl rollout status "${deployment}" -n lab-mesh --timeout=120s
  done
}

verify_traffic() {
  local url
  for url in http://httpbin-server:8000/get http://nginx-server http://whoami-server; do
    if ! kubectl exec -n lab-mesh deploy/mesh-client -c mesh-client -- curl -fsS --retry 2 --max-time 5 "${url}" >/dev/null; then
      echo "ERROR: migration traffic check failed for ${url}." >&2
      exit 1
    fi
  done
}

kubectl apply -f manifests/ambient/waypoint.yaml
kubectl wait --for=condition=programmed --timeout=120s gateway/waypoint -n lab-mesh
kubectl wait --for=condition=available --timeout=120s deployment/waypoint -n lab-mesh

kubectl label namespace lab-mesh istio.io/use-waypoint=waypoint --overwrite
kubectl label namespace lab-mesh istio.io/dataplane-mode=ambient --overwrite

ztunnel_workloads="$(istioctl ztunnel-config workloads -n istio-system --workload-namespace lab-mesh)"
if ! grep -q 'lab-mesh' <<<"${ztunnel_workloads}"; then
  echo "ERROR: lab-mesh workloads are not visible in ztunnel configuration." >&2
  exit 1
fi
verify_traffic

kubectl label namespace lab-mesh istio-injection- >/dev/null 2>&1 || true

kubectl rollout restart deployment -n lab-mesh -l "${LAB_SELECTOR}"
wait_for_lab_rollouts
all_pods_lack_sidecars
verify_traffic

echo "lab-mesh is migrated to Ambient mode with waypoint L7 processing."
