#!/usr/bin/env bash
# Approve ocpvirt-workloads-ha InstallPlans in order (resolves name + namespace).
set -euo pipefail

# namespace:subscription:csv_grep_pattern
STEPS=(
  "openshift-workload-availability:node-maintenance-operator:node-maintenance"
  "openshift-workload-availability:self-node-remediation:self-node-remediation"
  "openshift-workload-availability:node-healthcheck-operator:node-healthcheck"
  "openshift-kube-descheduler-operator:cluster-kube-descheduler-operator:descheduler"
)

usage() {
  echo "Usage: $0 [step]" >&2
  echo "  step: 1-4 to approve one operator, or omit to run all in order" >&2
  exit 1
}

find_installplan() {
  local namespace="$1"
  local subscription="$2"
  local csv_match="$3"
  local installplan=""

  installplan="$(oc get subscription "${subscription}" -n "${namespace}" \
    -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)"

  if [[ -n "${installplan}" ]]; then
    local approved
    approved="$(oc get installplan "${installplan}" -n "${namespace}" \
      -o jsonpath='{.spec.approved}' 2>/dev/null || true)"
    if [[ "${approved}" == "false" ]]; then
      echo "${installplan}"
      return 0
    fi
    if [[ "${approved}" == "true" ]]; then
      return 1
    fi
  fi

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local name="${line%%$'\t'*}"
    local csvs="${line#*$'\t'}"
    if [[ "${csvs}" == *"${csv_match}"* ]] || [[ "${csvs}" == *"${subscription}"* ]]; then
      echo "${name}"
      return 0
    fi
  done < <(oc get installplan -n "${namespace}" -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{"\t"}{.spec.clusterServiceVersionNames}{"\n"}{end}' 2>/dev/null || true)

  return 1
}

csv_succeeded() {
  local namespace="$1"
  local csv_match="$2"
  oc get csv -n "${namespace}" --no-headers 2>/dev/null \
    | grep -i "${csv_match}" \
    | awk '{print $NF}' \
    | grep -qx Succeeded
}

wait_csv() {
  local namespace="$1"
  local csv_match="$2"
  echo "Waiting for CSV matching ${csv_match} in ${namespace}..."
  for _ in $(seq 1 60); do
    if csv_succeeded "${namespace}" "${csv_match}"; then
      oc get csv -n "${namespace}" | grep -i "${csv_match}" || true
      return 0
    fi
    oc get csv -n "${namespace}" 2>/dev/null | grep -i "${csv_match}" || true
    sleep 10
  done
  echo "Timed out waiting for CSV matching ${csv_match}" >&2
  return 1
}

approve_step() {
  local namespace="$1"
  local subscription="$2"
  local csv_match="$3"

  echo "=== ${subscription} (${namespace}) ==="

  if csv_succeeded "${namespace}" "${csv_match}"; then
    echo "CSV already Succeeded for ${subscription}; skipping."
    return 0
  fi

  local installplan=""
  if ! installplan="$(find_installplan "${namespace}" "${subscription}" "${csv_match}")"; then
    echo "No pending InstallPlan found for ${subscription} in ${namespace}" >&2
    echo "Check: oc get subscription,installplan -n ${namespace}" >&2
    return 1
  fi

  local approved
  approved="$(oc get installplan "${installplan}" -n "${namespace}" -o jsonpath='{.spec.approved}')"
  if [[ "${approved}" == "true" ]]; then
    echo "InstallPlan ${installplan} already approved."
  else
    echo "Approving InstallPlan ${installplan} in ${namespace}..."
    oc patch installplan "${installplan}" -n "${namespace}" --type merge \
      -p '{"spec":{"approved":true}}'
  fi

  wait_csv "${namespace}" "${csv_match}"
}

STEP_ARG="${1:-}"
if [[ -n "${STEP_ARG}" ]]; then
  [[ "${STEP_ARG}" =~ ^[1-4]$ ]] || usage
  IFS=':' read -r ns sub csv <<< "${STEPS[$((STEP_ARG - 1))]}"
  approve_step "${ns}" "${sub}" "${csv}"
  exit 0
fi

for entry in "${STEPS[@]}"; do
  IFS=':' read -r ns sub csv <<< "${entry}"
  approve_step "${ns}" "${sub}" "${csv}"
done

echo "All InstallPlans approved and CSVs Succeeded."
