#!/usr/bin/env bash
# Trigger an Argo CD Application sync using oc only (official operation field).
set -euo pipefail

APP="${1:-}"
NS="${2:-openshift-gitops}"
FORCE="${FORCE:-false}"

if [[ -z "${APP}" ]]; then
  echo "Usage: $0 <application-name> [namespace]" >&2
  echo "Example: $0 openshift-workload-operators-config" >&2
  exit 1
fi

if ! oc get application "${APP}" -n "${NS}" >/dev/null 2>&1; then
  echo "Application not found: ${APP} in ${NS}" >&2
  exit 1
fi

echo "Refreshing ${APP}..."
oc patch application "${APP}" -n "${NS}" --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

echo "Clearing any stuck operation on ${APP}..."
oc patch application "${APP}" -n "${NS}" --type json \
  -p='[{"op":"remove","path":"/operation"}]' 2>/dev/null || true

if [[ "${FORCE}" == "true" ]]; then
  echo "Triggering force sync on ${APP}..."
  oc patch application "${APP}" -n "${NS}" --type merge -p '{
    "operation": {
      "initiatedBy": {"username": "oc"},
      "sync": {
        "syncStrategy": {
          "apply": {"force": true}
        }
      }
    }
  }'
else
  echo "Triggering sync on ${APP}..."
  oc patch application "${APP}" -n "${NS}" --type merge -p '{
    "operation": {
      "initiatedBy": {"username": "oc"},
      "sync": {
        "syncStrategy": {
          "hook": {}
        }
      }
    }
  }'
fi

echo "Waiting for sync to finish..."
for _ in $(seq 1 30); do
  phase="$(oc get application "${APP}" -n "${NS}" \
    -o jsonpath='{.status.operationState.phase}{"\n"}{.status.sync.status}{"\n"}{.status.health.status}' 2>/dev/null || true)"
  op_phase="$(echo "${phase}" | sed -n '1p')"
  sync_status="$(echo "${phase}" | sed -n '2p')"
  health="$(echo "${phase}" | sed -n '3p')"
  echo "  operation=${op_phase:-none} sync=${sync_status:-unknown} health=${health:-unknown}"
  if [[ -z "${op_phase}" || "${op_phase}" == "Succeeded" || "${op_phase}" == "Failed" || "${op_phase}" == "Error" ]]; then
    if [[ "${sync_status}" == "Synced" ]]; then
      echo "Done: ${APP} is Synced (${health})"
      exit 0
    fi
    if [[ "${op_phase}" == "Failed" || "${op_phase}" == "Error" ]]; then
      echo "Sync failed. Last message:" >&2
      oc get application "${APP}" -n "${NS}" \
        -o jsonpath='{.status.operationState.message}{"\n"}' >&2 || true
      exit 1
    fi
  fi
  sleep 5
done

echo "Timed out waiting for ${APP}. Check status:" >&2
oc get application "${APP}" -n "${NS}" \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OPERATION:.status.operationState.phase
exit 1
