#!/usr/bin/env bash
set -euo pipefail

FAILED=0

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1" >&2
  FAILED=1
}

check_label() {
  local ns="$1" label="$2" expected="$3" actual
  actual="$(kubectl get namespace "${ns}" --show-labels 2>/dev/null | awk 'NR == 2 {print $NF}' | tr ',' '\n' | awk -F= -v label="${label}" '$1 == label {print $2}')"

  if [[ "${actual}" == "${expected}" ]]; then
    pass "${ns} has ${label}=${expected}"
  else
    fail "${ns} expected ${label}=${expected}, found ${actual:-unset}"
  fi
}

check_label_absent() {
  local ns="$1" label="$2" actual
  actual="$(kubectl get namespace "${ns}" --show-labels 2>/dev/null | awk 'NR == 2 {print $NF}' | tr ',' '\n' | awk -F= -v label="${label}" '$1 == label {print $2}')"

  if [[ -z "${actual}" ]]; then
    pass "${ns} has no ${label} label"
  else
    fail "${ns} still has ${label}=${actual}"
  fi
}

check_rollout() {
  if kubectl rollout status "$1" -n "$2" --timeout=60s >/dev/null 2>&1; then
    pass "$2/$1 is ready"
  else
    fail "$2/$1 is not ready"
  fi
}

check_no_sidecars() {
  local pod state deleting containers found=0
  for pod in $(kubectl get pods -n lab-mesh -l app.kubernetes.io/part-of=istio-mtls-lab -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    state="$(kubectl get pod "${pod}" -n lab-mesh -o jsonpath='{.metadata.deletionTimestamp}{"|"}{.spec.containers[*].name}' 2>/dev/null || true)"
    [[ -z "${state}" ]] && continue
    deleting="${state%%|*}"
    containers="${state#*|}"
    [[ -n "${deleting}" ]] && continue
    if grep -qw istio-proxy <<<"${containers}"; then
      fail "${pod} still has istio-proxy"
      found=1
    fi
  done

  if [[ "${found}" -eq 0 ]]; then
    pass "lab-mesh application pods have no istio-proxy"
  fi
}

check_external_outside_mesh() {
  local labels containers
  labels="$(kubectl get namespace lab-external --show-labels 2>/dev/null || true)"
  containers="$(kubectl get pods -n lab-external -o jsonpath='{.items[*].spec.containers[*].name}' 2>/dev/null || true)"

  if printf '%s\n' "${labels}" | grep -Eq 'istio-injection=|istio.io/dataplane-mode='; then
    fail "lab-external has mesh enrollment labels"
  elif printf '%s\n' "${containers}" | grep -qw istio-proxy; then
    fail "lab-external pod has istio-proxy"
  else
    pass "lab-external remains outside the mesh"
  fi
}

check_ztunnel_hbone() {
  local output
  output="$(istioctl ztunnel-config workloads -n istio-system --workload-namespace lab-mesh 2>/dev/null || true)"

  if printf '%s\n' "${output}" | grep -q 'lab-mesh' && printf '%s\n' "${output}" | grep -q 'HBONE'; then
    pass "ztunnel config shows lab-mesh workloads using HBONE"
  else
    fail "ztunnel config does not show lab-mesh workloads using HBONE"
  fi
}

check_request() {
  local name="$1" url="$2"
  local ok=0

  for _ in 1 2 3; do
    if kubectl exec -n lab-mesh deploy/mesh-client -c mesh-client -- curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 2
  done

  if [[ "${ok}" -eq 1 ]]; then
    pass "mesh-client reaches ${name}"
  else
    fail "mesh-client cannot reach ${name}"
  fi
}

check_label lab-mesh istio.io/dataplane-mode ambient
check_label lab-mesh istio.io/use-waypoint waypoint
check_label_absent lab-mesh istio-injection
check_rollout daemonset/ztunnel istio-system
check_rollout daemonset/istio-cni-node istio-system
kubectl wait --for=condition=programmed --timeout=60s gateway/waypoint -n lab-mesh >/dev/null 2>&1 && pass "lab-mesh/waypoint Gateway is programmed" || fail "lab-mesh/waypoint Gateway is not programmed"
check_rollout deployment/waypoint lab-mesh
check_no_sidecars
check_ztunnel_hbone
check_request httpbin-server http://httpbin-server:8000/get
check_request nginx-server http://nginx-server
check_request whoami-server http://whoami-server
check_external_outside_mesh

if [[ "${FAILED}" -ne 0 ]]; then
  exit 1
fi
