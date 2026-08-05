#!/usr/bin/env bash
set -euo pipefail

LAB_SELECTOR="app.kubernetes.io/part-of=istio-mtls-lab"

all_pods_have_sidecars() {
  local pod state deleting containers
  for pod in $(kubectl get pods -n lab-mesh -l app.kubernetes.io/part-of=istio-mtls-lab -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    state="$(kubectl get pod "${pod}" -n lab-mesh -o jsonpath='{.metadata.deletionTimestamp}{"|"}{.spec.containers[*].name}' 2>/dev/null || true)"
    [[ -z "${state}" ]] && continue
    deleting="${state%%|*}"
    containers="${state#*|}"
    [[ -n "${deleting}" ]] && continue
    if ! grep -qw istio-proxy <<<"${containers}"; then
      echo "ERROR: pod ${pod} does not have istio-proxy." >&2
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

kubectl label namespace lab-mesh istio-injection=enabled --overwrite
kubectl rollout restart deployment -n lab-mesh -l "${LAB_SELECTOR}"
wait_for_lab_rollouts
all_pods_have_sidecars

kubectl label namespace lab-mesh istio.io/dataplane-mode- >/dev/null 2>&1 || true
kubectl label namespace lab-mesh istio.io/use-waypoint- >/dev/null 2>&1 || true
kubectl apply -n lab-mesh -f manifests/peerauthentication-strict.yaml

all_pods_have_sidecars
./scripts/04-test-mtls-mode.sh strict

echo "lab-mesh is back in sidecar mode. Ambient components remain installed cluster-wide."
