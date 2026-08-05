#!/usr/bin/env bash
set -euo pipefail

ISTIO_VERSION="1.30.1"
GATEWAY_API_VERSION="v1.5.1"
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
LAB_SELECTOR="app.kubernetes.io/part-of=istio-mtls-lab"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: $1 is not installed or not on PATH." >&2
    exit 1
  fi
}

require_istio_version() {
  local installed
  installed="$(istioctl version --remote=false 2>/dev/null | awk '/client version:/ {print $3; exit}')"

  if [[ "${installed}" != "${ISTIO_VERSION}" ]]; then
    echo "ERROR: This lab requires istioctl ${ISTIO_VERSION}; found ${installed:-unknown}." >&2
    exit 1
  fi
}

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

verify_ztunnel_ready() {
  local desired ready
  desired="$(kubectl get daemonset ztunnel -n istio-system -o jsonpath='{.status.desiredNumberScheduled}')"
  ready="$(kubectl get daemonset ztunnel -n istio-system -o jsonpath='{.status.numberReady}')"

  if [[ -z "${desired}" || "${desired}" != "${ready}" ]]; then
    echo "ERROR: ztunnel is not ready on every node (${ready:-0}/${desired:-0})." >&2
    exit 1
  fi
}

wait_for_lab_rollouts() {
  local deployment
  for deployment in $(kubectl get deployment -n lab-mesh -l "${LAB_SELECTOR}" -o name); do
    kubectl rollout status "${deployment}" -n lab-mesh --timeout=120s
  done
}

require_command kubectl
require_command istioctl
require_istio_version

if ! kubectl get crd gateways.gateway.networking.k8s.io gatewayclasses.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  kubectl apply --server-side -f "${GATEWAY_API_URL}"
fi

istioctl upgrade --set profile=ambient --skip-confirmation

kubectl rollout status deployment/istiod -n istio-system
kubectl rollout status daemonset/istio-cni-node -n istio-system
kubectl rollout status daemonset/ztunnel -n istio-system
verify_ztunnel_ready

kubectl rollout restart deployment -n lab-mesh -l "${LAB_SELECTOR}"
wait_for_lab_rollouts
all_pods_have_sidecars

kubectl apply -f manifests/ambient/waypoint.yaml
kubectl wait --for=condition=programmed --timeout=120s gateway/waypoint -n lab-mesh
kubectl wait --for=condition=available --timeout=120s deployment/waypoint -n lab-mesh

echo "Ambient components are installed. lab-mesh still uses sidecars; waypoint is ready but not activated."
