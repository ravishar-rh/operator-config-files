#!/usr/bin/env bash
# Regenerate install/config manifests and GitOps layout from ~/Downloads/gitops charts.
set -euo pipefail

HELM="${HELM:-$(command -v helm)}"
GITOPS="${GITOPS:-${HOME}/Downloads/gitops}"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKLOAD_NAMESPACE="openshift-workload-availability"
BASE_DIR="${OUT_DIR}/base/${WORKLOAD_NAMESPACE}"
CLUSTER_OVERLAY="${OUT_DIR}/clusters/ocp"
CLUSTER_INSTALL="${CLUSTER_OVERLAY}/install"
CLUSTER_CONFIG="${CLUSTER_OVERLAY}/config"

DEFAULT_OPERATORS=(
  node-maintenance-operator
  self-node-remediation-operator
  node-health-check-operator
  kube-descheduler-operator
)

OPTIONAL_OPERATORS=(
  fence-agents-remediation-operator
  machine-deletion-remediation-operator
)

if [[ -z "${HELM}" || ! -x "${HELM}" ]]; then
  echo "helm is required but was not found in PATH" >&2
  exit 1
fi

if [[ ! -d "${GITOPS}" ]]; then
  echo "gitops charts directory not found: ${GITOPS}" >&2
  exit 1
fi

write_documents() {
  local target_dir="$1"
  local rendered="$2"
  local skip_namespace="${3:-false}"
  local only_kinds="${4:-}"

  mkdir -p "${target_dir}"
  find "${target_dir}" -maxdepth 1 -type f -name '*.yaml' -delete

  awk -v target_dir="${target_dir}" -v skip_namespace="${skip_namespace}" -v only_kinds="${only_kinds}" '
    function trim(s) {
      sub(/^[ \t\r\n]+/, "", s)
      sub(/[ \t\r\n]+$/, "", s)
      return s
    }
    function kind_allowed(kind) {
      if (only_kinds == "") return 1
      return index(" " only_kinds " ", " " kind " ") > 0
    }
    function flush_doc() {
      if (doc == "") return
      kind = ""
      name = ""
      n = split(doc, lines, "\n")
      for (i = 1; i <= n; i++) {
        if (lines[i] ~ /^kind:[[:space:]]*/) {
          kind = trim(substr(lines[i], index(lines[i], ":") + 1))
        }
        if (lines[i] ~ /^  name:[[:space:]]*/) {
          name = trim(substr(lines[i], index(lines[i], ":") + 1))
        }
      }
      if (kind == "" || name == "") {
        doc = ""
        return
      }
      if (skip_namespace == "true" && kind == "Namespace") {
        doc = ""
        return
      }
      if (!kind_allowed(kind)) {
        doc = ""
        return
      }
      slug = kind
      if (kind == "Namespace") slug = "namespace"
      else if (kind == "OperatorGroup") slug = "operatorgroup"
      else if (kind == "Subscription") slug = "subscription"
      else if (kind == "Secret") slug = "secret"
      else if (kind == "SelfNodeRemediationTemplate") slug = "self-node-remediation-template"
      else if (kind == "FenceAgentsRemediationTemplate") slug = "fence-agents-remediation-template"
      else if (kind == "MachineDeletionRemediationTemplate") slug = "machine-deletion-template"
      else if (kind == "NodeHealthCheck") slug = "node-health-check"
      else if (kind == "KubeDescheduler") slug = "kube-descheduler"
      else {
        gsub(/[^a-zA-Z0-9]+/, "-", slug)
        slug = tolower(slug)
      }
      filename = slug
      if (kind != "Namespace" && kind != "OperatorGroup" && kind != "Subscription") {
        filename = filename "-" name
      }
      gsub(/[^a-zA-Z0-9._-]+/, "-", filename)
      print doc > (target_dir "/" filename ".yaml")
      close(target_dir "/" filename ".yaml")
      doc = ""
    }
    /^---$/ {
      flush_doc()
      next
    }
    {
      if ($0 ~ /^# Source:/) next
      if (doc == "") doc = $0
      else doc = doc "\n" $0
    }
    END { flush_doc() }
  ' "${rendered}"
}

write_kustomization() {
  local dir="$1"
  shift
  local resources=("$@")

  {
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "resources:"
    for resource in "${resources[@]}"; do
      echo "  - ${resource}"
    done
  } > "${dir}/kustomization.yaml"
}

extract_chart() {
  local chart_dir="$1"
  local release="$2"
  shift 2
  local extra_sets=()
  if (($# > 0)); then
    extra_sets=("$@")
  fi
  local chart_path="${GITOPS}/${chart_dir}"
  local out="${OUT_DIR}/${chart_dir}"
  local install_dir="${out}/install"
  local config_dir="${out}/config"
  local rendered
  local install_kinds="Namespace OperatorGroup Subscription"

  if [[ ! -d "${chart_path}" ]]; then
    echo "skip missing chart: ${chart_path}" >&2
    return 0
  fi

  echo "extracting ${chart_dir}"

  rendered="$(mktemp)"
  if ((${#extra_sets[@]} > 0)); then
    "${HELM}" template "${release}" "${chart_path}" \
      --show-only templates/operator.yaml \
      "${extra_sets[@]}" > "${rendered}"
  else
    "${HELM}" template "${release}" "${chart_path}" \
      --show-only templates/operator.yaml > "${rendered}"
  fi

  if [[ "${chart_dir}" == "kube-descheduler-operator" ]]; then
    write_documents "${install_dir}" "${rendered}" false "${install_kinds}"
  else
    write_documents "${install_dir}" "${rendered}" false "Subscription"
  fi

  install_resources=()
  while IFS= read -r file; do
    install_resources+=("$(basename "${file}")")
  done < <(find "${install_dir}" -maxdepth 1 -type f -name '*.yaml' | sort)
  write_kustomization "${install_dir}" "${install_resources[@]}"

  rendered_config="$(mktemp)"
  if ((${#extra_sets[@]} > 0)); then
    helm_config_cmd=(
      "${HELM}" template "${release}" "${chart_path}"
      --show-only templates/config.yaml
      "${extra_sets[@]}"
    )
  else
    helm_config_cmd=(
      "${HELM}" template "${release}" "${chart_path}"
      --show-only templates/config.yaml
    )
  fi
  if "${helm_config_cmd[@]}" > "${rendered_config}" 2>/dev/null; then
    if grep -q '^kind:' "${rendered_config}"; then
      write_documents "${config_dir}" "${rendered_config}" true
      config_resources=()
      while IFS= read -r file; do
        config_resources+=("$(basename "${file}")")
      done < <(find "${config_dir}" -maxdepth 1 -type f -name '*.yaml' | sort)
      write_kustomization "${config_dir}" "${config_resources[@]}"
    else
      rm -rf "${config_dir}"
    fi
  else
    rm -rf "${config_dir}"
  fi

  operator_resources=("install/subscription.yaml")
  if [[ "${chart_dir}" == "kube-descheduler-operator" ]]; then
    operator_resources=("install")
  fi
  if [[ -d "${config_dir}" ]]; then
    operator_resources+=("config")
  fi
  write_kustomization "${out}" "${operator_resources[@]}"

  rm -f "${rendered}" "${rendered_config}"
}

write_shared_base() {
  local rendered
  rendered="$(mktemp)"
  "${HELM}" template node-maintenance "${GITOPS}/node-maintenance-operator" \
    --show-only templates/operator.yaml > "${rendered}"
  write_documents "${BASE_DIR}" "${rendered}" false "Namespace OperatorGroup"
  write_kustomization "${BASE_DIR}" "namespace.yaml" "operatorgroup.yaml"
  rm -f "${rendered}"
}

write_cluster_overlays() {
  local operators=("$@")
  local install_resources=("../../../base/${WORKLOAD_NAMESPACE}")
  local config_resources=()

  for operator in "${operators[@]}"; do
    install_resources+=("../../../${operator}/install")
    if [[ -d "${OUT_DIR}/${operator}/config" ]]; then
      config_resources+=("../../../${operator}/config")
    fi
  done

  mkdir -p "${CLUSTER_INSTALL}" "${CLUSTER_CONFIG}"
  write_kustomization "${CLUSTER_INSTALL}" "${install_resources[@]}"
  write_kustomization "${CLUSTER_CONFIG}" "${config_resources[@]}"

  cat > "${CLUSTER_OVERLAY}/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - install
  - config
EOF
}

patch_operatorgroup_install_mode() {
  local og="${BASE_DIR}/operatorgroup.yaml"
  if [[ -f "${og}" ]]; then
    # Empty spec = AllNamespaces. targetNamespaces matching the operator
    # namespace triggers OwnNamespace, which these operators do not support.
    cat > "${og}" <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-workload-availability
  namespace: openshift-workload-availability
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec: {}
EOF
  fi
}

patch_config_sync_waves() {
  local nhc="${OUT_DIR}/node-health-check-operator/config/node-health-check-nhc-all-linux-nodes.yaml"
  local kd="${OUT_DIR}/kube-descheduler-operator/config/kube-descheduler-cluster.yaml"
  if [[ -f "${nhc}" ]]; then
    sed -i '' 's/argocd.argoproj.io\/sync-wave: "6"/argocd.argoproj.io\/sync-wave: "7"/' "${nhc}"
  fi
  if [[ -f "${kd}" ]]; then
    sed -i '' 's/argocd.argoproj.io\/sync-wave: "5"/argocd.argoproj.io\/sync-wave: "8"/' "${kd}"
  fi
}

write_argocd_applications() {
  local apps_dir="${OUT_DIR}/argocd/applications"
  mkdir -p "${apps_dir}"

  cat > "${apps_dir}/openshift-workload-operators-install.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openshift-workload-operators-install
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: git@github.com:ravishar-rh/operator-config-files.git
    targetRevision: main
    path: clusters/ocp/install
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
  ignoreDifferences:
    - group: operators.coreos.com
      kind: Subscription
      jqPathExpressions:
        - .status
        - .spec.startingCSV
    - group: operators.coreos.com
      kind: InstallPlan
      jqPathExpressions:
        - .spec.approved
        - .status
EOF

  cat > "${apps_dir}/openshift-workload-operators-config.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openshift-workload-operators-config
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: git@github.com:ravishar-rh/operator-config-files.git
    targetRevision: main
    path: clusters/ocp/config
  destination:
    server: https://kubernetes.default.svc
  dependsOn:
    - name: openshift-workload-operators-install
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
      - SkipDryRunOnMissingResource=true
    retry:
      limit: -1
      backoff:
        duration: 1m
        factor: 2
        maxDuration: 10m
EOF

  cat > "${apps_dir}/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - openshift-workload-operators-install.yaml
  - openshift-workload-operators-config.yaml
EOF

  cat > "${apps_dir}/root.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: operator-config-files-root
  namespace: openshift-gitops
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: git@github.com:ravishar-rh/operator-config-files.git
    targetRevision: main
    path: argocd/applications
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
EOF
}

write_shared_base
patch_operatorgroup_install_mode

extract_chart node-maintenance-operator node-maintenance
extract_chart self-node-remediation-operator self-node-remediation \
  --set selfNodeRemediation.enabled=true
extract_chart fence-agents-remediation-operator fence-agents-remediation \
  --set fenceAgentsRemediation.enabled=true
extract_chart machine-deletion-remediation-operator machine-deletion-remediation \
  --set machineDeletionRemediation.enabled=true
extract_chart node-health-check-operator node-health-check \
  --set nodeHealthCheck.enabled=true
extract_chart kube-descheduler-operator kube-descheduler \
  --set deschedulerConfig.enabled=true

write_cluster_overlays "${DEFAULT_OPERATORS[@]}"
patch_config_sync_waves
write_argocd_applications

if command -v kubectl >/dev/null 2>&1; then
  echo "validating clusters/ocp/install kustomize build"
  if ! kubectl kustomize "${CLUSTER_INSTALL}" | grep -q '^kind:'; then
    echo "kustomize build for clusters/ocp/install produced no resources" >&2
    exit 1
  fi
  echo "validating clusters/ocp/config kustomize build"
  if ! kubectl kustomize "${CLUSTER_CONFIG}" | grep -q '^kind:'; then
    echo "kustomize build for clusters/ocp/config produced no resources" >&2
    exit 1
  fi
  echo "validating argocd/applications kustomize build"
  kubectl kustomize "${OUT_DIR}/argocd/applications" >/dev/null
fi

echo "done: ${OUT_DIR}"
