#!/usr/bin/env bash
# Apply ocpvirt-workloads-ha KubeDescheduler config directly with oc.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_DIR="${REPO_DIR}/modules/ocpvirt-workloads-ha"
CONFIG_DIR="${MODULE_DIR}/overlays/config-descheduler"
CRD="kubedeschedulers.operator.openshift.io"
NS="openshift-kube-descheduler-operator"

echo "Checking descheduler operator..."
if ! oc get crd "${CRD}" >/dev/null 2>&1; then
  echo "CRD missing: ${CRD}" >&2
  echo "Approve InstallPlan step 4 (cluster-kube-descheduler-operator) first:" >&2
  echo "  ./scripts/approve-installplan.sh 4" >&2
  exit 1
fi

if ! oc get csv -n "${NS}" --no-headers 2>/dev/null \
  | grep -i descheduler | awk '{print $NF}' | grep -qx Succeeded; then
  echo "Descheduler CSV not Succeeded yet in ${NS}." >&2
  oc get csv -n "${NS}" 2>/dev/null || true
  echo "Run: ./scripts/approve-installplan.sh 4" >&2
  exit 1
fi

echo "Applying config from ${CONFIG_DIR}..."
oc apply -k "${CONFIG_DIR}"

echo "Verifying KubeDescheduler..."
oc get kubedescheduler cluster

echo "Refreshing Argo CD app so it matches cluster state..."
if oc get application ocpvirt-workloads-ha-descheduler-config -n openshift-gitops >/dev/null 2>&1; then
  oc patch application ocpvirt-workloads-ha-descheduler-config -n openshift-gitops --type merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
fi

echo "Done."
