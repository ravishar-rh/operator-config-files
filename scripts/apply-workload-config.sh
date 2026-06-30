#!/usr/bin/env bash
# Apply workload config CRs directly with oc (bypasses Argo CD sync issues).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${REPO_DIR}/clusters/ocp/config"

echo "Checking operator CRDs..."
for crd in \
  selfnoderemediationtemplates.self-node-remediation.medik8s.io \
  nodehealthchecks.remediation.medik8s.io; do
  if ! oc get crd "${crd}" >/dev/null 2>&1; then
    echo "CRD missing: ${crd}" >&2
    echo "Approve self-node-remediation and node-healthcheck InstallPlans first." >&2
    exit 1
  fi
done

echo "Applying config from ${CONFIG_DIR}..."
oc apply -k "${CONFIG_DIR}"

echo "Verifying resources..."
oc get selfnoderemediationtemplate -n openshift-workload-availability
oc get nodehealthcheck -n openshift-workload-availability

echo "Refreshing Argo CD app so it matches cluster state..."
if oc get application openshift-workload-operators-config -n openshift-gitops >/dev/null 2>&1; then
  oc patch application openshift-workload-operators-config -n openshift-gitops --type merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
fi

echo "Done."
