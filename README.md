# operator-config-files

GitOps-ready OpenShift Virtualization workload HA operators, packaged as the
**ocpvirt-workloads-ha** Kustomize module. Argo CD deploys operator install and
config in two phases using OLM Classic (`Subscription` / `OperatorGroup`).

Repository: https://github.com/ravishar-rh/operator-config-files

## Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Quick reference](#quick-reference)
- [Deployment guide](#deployment-guide)
- [Recovery and cleanup](#recovery-and-cleanup)
- [Day-to-day operations](#day-to-day-operations)
- [Troubleshooting](#troubleshooting)
- [Customization](#customization)
- [Notes](#notes)

## Overview

```
.
├── modules/ocpvirt-workloads-ha/     # Kustomize module (install + config)
│   ├── components/                   # Per-operator install/config bases
│   ├── overlays/                     # install, config, config-descheduler, all
│   └── argocd/                       # Argo CD Applications + RBAC
└── scripts/                          # oc-only sync helpers
```

Module-level layout, kustomize builds, and bootstrap commands:
[modules/ocpvirt-workloads-ha/README.md](modules/ocpvirt-workloads-ha/README.md)

## Architecture

### Operators installed (Phase 1)

| Namespace | Subscription (package) |
|-----------|------------------------|
| `openshift-workload-availability` | `node-maintenance-operator` |
| `openshift-workload-availability` | `self-node-remediation` |
| `openshift-workload-availability` | `node-healthcheck-operator` |
| `openshift-kube-descheduler-operator` | `cluster-kube-descheduler-operator` |

Also creates shared `Namespace` and `OperatorGroup` resources (sync-waves 0 and 1).
The workload OperatorGroup uses `spec: {}` (AllNamespaces mode) — do not set
`targetNamespaces` to the same namespace or operator installs will fail.

### Config CRs applied (Phase 2)

| Resource | Sync wave | Requires |
|----------|-----------|----------|
| `SelfNodeRemediationTemplate/self-node-remediation-resource-deletion-template` | 6 | Self-node-remediation operator CRD |
| `NodeHealthCheck/nhc-all-linux-nodes` | 7 | Node-health-check operator CRD + SNR template |
| `KubeDescheduler/cluster` | 8 | Kube descheduler operator CRD |

### Argo CD Applications

| Application | Path | Purpose |
|-------------|------|---------|
| `ocpvirt-workloads-ha-root` | `modules/ocpvirt-workloads-ha/argocd/applications` | App-of-Apps parent |
| `ocpvirt-workloads-ha-install` | `overlays/install` | OLM subscriptions |
| `ocpvirt-workloads-ha-config` | `overlays/config` | Namespaced config CRs |
| `ocpvirt-workloads-ha-descheduler-config` | `overlays/config-descheduler` | Cluster-scoped KubeDescheduler |

Paths are relative to `modules/ocpvirt-workloads-ha/`.

### Why multiple Argo CD Applications?

**Install vs config** — OLM subscriptions only create InstallPlans. Operator CRDs
such as `NodeHealthCheck` are registered only after you approve InstallPlans and
the CSV install completes. If config CRs sync in the same Application, Argo CD
reports:

```
Resource not found in cluster: remediation.medik8s.io/v1alpha1/NodeHealthCheck:nhc-all-linux-nodes
```

Phase 1 applies subscriptions. Phase 2 applies config CRs after phase 1 syncs,
with unlimited retry until CRDs exist.

**Config vs descheduler-config** — `KubeDescheduler` is cluster-scoped (no
namespace). Argo CD cannot deploy it in the same Application as namespaced CRs
without `InvalidSpecError: Namespace ... is missing`.

### OLM Classic vs OLM v1

This module installs operators using **OLM Classic (OLM v0)** — the
Subscription / OperatorGroup / InstallPlan model that ships with OpenShift 4.
It does **not** use OLM v1 `ClusterExtension` resources.

| | OLM Classic (this module) | OLM v1 |
|---|---------------------------|--------|
| **Install API** | `Subscription`, `OperatorGroup`, `InstallPlan` | `ClusterExtension` (`olm.operatorframework.io/v1`) |
| **Scope** | Namespace-scoped or cluster-wide via `OperatorGroup` | Cluster-scoped only |
| **Security model** | OLM grants operator RBAC from the CSV | Admin provides a `ServiceAccount` with explicit permissions |
| **Catalog** | `CatalogSource` + index image (e.g. `redhat-operators`) | `catalogd` + file-based catalog (FBC) content |
| **GitOps fit** | Works; requires patterns documented in this README | Designed for declarative, GitOps-native lifecycle |
| **OpenShift status** | Fully supported for the entire OCP 4 lifecycle | GA from OpenShift 4.19; Classic OLM remains supported in parallel |
| **OperatorHub / console** | Full support in OperatorHub and Installed Operators | OLM v1 extensions not fully surfaced in OperatorHub UI (as of 4.19 docs) |
| **Upgrade model** | Channel + `installPlanApproval` on `Subscription` | Version pinning or ranges on `ClusterExtension` |

References:

- [OpenShift 4.19 Extensions overview](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/extensions/extensions-overview)
- [Manage operators with ClusterExtensions (OLM v1)](https://developers.redhat.com/articles/2025/06/02/manage-operators-clusterextensions-olm-v1)

#### OLM v1 operator package requirements (GA)

OLM v1 (OpenShift 4.19+) currently installs operator packages that meet **all**
of the following:

| Requirement | Notes |
|-------------|-------|
| `registry+v1` bundle format | Standard Red Hat operator bundles qualify |
| **AllNamespaces** install mode supported | Must not require OwnNamespace-only install |
| **No admission webhooks** | Many Operator SDK operators use webhooks and are excluded |
| **No file-based catalog dependencies** | Standalone packages only |

#### Recommendation

**Stay on OLM Classic for this module.**

| Factor | Why Classic OLM fits |
|--------|----------------------|
| **Red Hat NOV path** | NOV GitOps and Workload Availability docs target `Subscription` + `redhat-operators` |
| **Package compatibility** | Workload HA operators may not meet OLM v1 requirements (webhooks, install modes) |
| **GitOps work already done** | Install/config split, sync-waves, InstallPlan approval, and Argo CD RBAC are solved |
| **Runtime behavior** | Operator CRs behave the same regardless of which OLM generation installed them |
| **Support lifecycle** | Red Hat commits to Classic OLM support throughout OpenShift 4 |

Revisit OLM v1 when the cluster runs OpenShift 4.19+, Red Hat publishes
`ClusterExtension` manifests for this operator set, and each package is confirmed
compatible.

## Quick reference

### InstallPlan approval order

Approve **one at a time**. Wait for each CSV to reach **Succeeded** before the
next. Do not approve all InstallPlans at once.

| Order | Operator | Namespace |
|-------|----------|-----------|
| 1 | `node-maintenance-operator` | `openshift-workload-availability` |
| 2 | `self-node-remediation` | `openshift-workload-availability` |
| 3 | `node-healthcheck-operator` | `openshift-workload-availability` |
| 4 | `cluster-kube-descheduler-operator` | `openshift-kube-descheduler-operator` |

```sh
oc get installplan -n openshift-workload-availability   # or openshift-kube-descheduler-operator
oc patch installplan <name> -n <namespace> --type merge -p '{"spec":{"approved":true}}'
watch oc get csv -n <namespace>
```

### Deployment flow

```
Apply root.yaml
  → Install app syncs subscriptions
    → Approve operators in order (see table above)
  → All CRDs Established
    → Config apps sync:
        SelfNodeRemediationTemplate (wave 6)
        NodeHealthCheck (wave 7)
        KubeDescheduler (wave 8)
```

### One-time cluster setup

```sh
oc apply -f modules/ocpvirt-workloads-ha/argocd/rbac/ocpvirt-workloads-ha-argocd-rbac.yaml
oc apply -f modules/ocpvirt-workloads-ha/argocd/applications/root.yaml
```

## Deployment guide

If a previous attempt failed, start with
[Recovery and cleanup](#recovery-and-cleanup) first.

### Prerequisites

```sh
oc whoami
oc get ns openshift-gitops
oc get pods -n openshift-gitops
```

Grant the Argo CD application controller permission to create operator config
CRs (required once per cluster):

```sh
oc apply -f modules/ocpvirt-workloads-ha/argocd/rbac/ocpvirt-workloads-ha-argocd-rbac.yaml

oc auth can-i patch selfnoderemediationtemplates \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller \
  -n openshift-workload-availability
# Expected: yes
```

All steps below use `oc` only — no local `argocd` CLI required.

### Step 1 — Push repo and register in Argo CD

```sh
cd /path/to/operator-config-files
git push origin main
```

Argo CD Applications use SSH: `git@github.com:ravishar-rh/operator-config-files.git`

#### SSH (recommended)

Add your SSH public key as a deploy key on GitHub:
https://github.com/ravishar-rh/operator-config-files/settings/keys → **Add deploy key**
(read-only is sufficient).

```sh
oc create secret generic repo-operator-config-files \
  -n openshift-gitops \
  --from-literal=type=git \
  --from-literal=url=git@github.com:ravishar-rh/operator-config-files.git \
  --from-file=sshPrivateKey="${HOME}/.ssh/id_ed25519"

oc label secret repo-operator-config-files \
  -n openshift-gitops \
  argocd.argoproj.io/secret-type=repository

oc get secret -n openshift-gitops -l argocd.argoproj.io/secret-type=repository
```

#### HTTPS instead of SSH

```sh
oc create secret generic repo-operator-config-files \
  -n openshift-gitops \
  --from-literal=type=git \
  --from-literal=url=https://github.com/ravishar-rh/operator-config-files.git \
  --from-literal=username=git \
  --from-literal=password=<github-pat>

oc label secret repo-operator-config-files \
  -n openshift-gitops \
  argocd.argoproj.io/secret-type=repository
```

### Step 2 — Remove legacy Applications (if upgrading)

```sh
for app in openshift-workload-operators openshift-workload-operators-install \
           openshift-workload-operators-config openshift-workload-operators-descheduler-config \
           operator-config-files-root; do
  oc delete application "${app}" -n openshift-gitops --ignore-not-found
done
```

### Step 3 — Bootstrap

```sh
oc apply -f modules/ocpvirt-workloads-ha/argocd/applications/root.yaml
oc get applications -n openshift-gitops
```

### Step 4 — Confirm Phase 1 sync

```sh
oc get application ocpvirt-workloads-ha-install -n openshift-gitops
oc get subscription -n openshift-workload-availability
oc get subscription -n openshift-kube-descheduler-operator
oc get installplan -n openshift-workload-availability
oc get installplan -n openshift-kube-descheduler-operator
```

### Step 5 — Approve InstallPlans

Follow the [InstallPlan approval order](#installplan-approval-order). Step 2
(self-node-remediation) must succeed before step 3 — `NodeHealthCheck` references
the `SelfNodeRemediationTemplate`.

### Step 6 — Verify CRDs

```sh
oc get crd selfnoderemediationtemplates.self-node-remediation.medik8s.io
oc get crd nodehealthchecks.remediation.medik8s.io
oc get crd kubedeschedulers.operator.openshift.io
```

All should exist and be **Established**.

### Step 7 — Confirm Phase 2 sync

```sh
oc get application ocpvirt-workloads-ha-config -n openshift-gitops
oc get application ocpvirt-workloads-ha-descheduler-config -n openshift-gitops
```

If still failing after all CSVs are Succeeded:

```sh
./scripts/apply-workload-config.sh
./scripts/sync-application.sh ocpvirt-workloads-ha-config
./scripts/sync-application.sh ocpvirt-workloads-ha-descheduler-config
```

Verify:

```sh
oc get selfnoderemediationtemplate -n openshift-workload-availability
oc get nodehealthcheck -n openshift-workload-availability
oc get kubedescheduler cluster
```

## Recovery and cleanup

Use when operators are stuck in **Failed**, InstallPlans were approved in the
wrong order, the OperatorGroup is misconfigured, or config CRs will not sync.

### When to use which reset

| Situation | Reset level |
|-----------|-------------|
| One CSV failed, others fine | [Level 1](#level-1-reset-operators-keep-argocd) |
| OwnNamespace / OperatorGroup error | [Level 1](#level-1-reset-operators-keep-argocd) |
| Multiple failed CSVs, bad InstallPlan order | [Level 1](#level-1-reset-operators-keep-argocd) |
| Argo CD apps OutOfSync / stuck operations | [Level 2](#level-2-full-reset-including-argocd-apps) |
| Namespaces corrupted or want completely clean slate | [Level 3](#level-3-delete-namespaces-nuclear) |

### Level 1 — Reset operators (keep Argo CD)

Removes OLM state and config CRs. Keeps Argo CD Applications and namespaces.

```sh
oc delete nodehealthcheck --all -n openshift-workload-availability --ignore-not-found
oc delete selfnoderemediationtemplate --all -n openshift-workload-availability --ignore-not-found
oc delete kubedescheduler cluster --ignore-not-found

oc delete subscription --all -n openshift-workload-availability
oc delete csv --all -n openshift-workload-availability
oc delete installplan --all -n openshift-workload-availability

oc delete subscription --all -n openshift-kube-descheduler-operator
oc delete csv --all -n openshift-kube-descheduler-operator
oc delete installplan --all -n openshift-kube-descheduler-operator

oc delete operatorgroup openshift-workload-availability -n openshift-workload-availability --ignore-not-found
oc apply -f modules/ocpvirt-workloads-ha/components/base-openshift-workload-availability/operatorgroup.yaml

./scripts/sync-application.sh ocpvirt-workloads-ha-install
```

Continue from [Step 5 — Approve InstallPlans](#step-5--approve-installplans).

### Level 2 — Full reset (including Argo CD apps)

Use when Argo CD itself is stuck or Level 1 did not clear the failure.

**Why simple `oc delete application` often fails:**

1. **App-of-apps recreates child apps** — `ocpvirt-workloads-ha-root` has automated sync.
2. **Finalizers block deletion** — apps use `resources-finalizer.argocd.argoproj.io`.
3. **Apps stuck in Terminating** — remove finalizers manually (step D below).

```sh
# A — Delete managed resources first
oc delete nodehealthcheck --all -n openshift-workload-availability --ignore-not-found
oc delete selfnoderemediationtemplate --all -n openshift-workload-availability --ignore-not-found
oc delete kubedescheduler cluster --ignore-not-found
oc delete subscription,csv,installplan --all -n openshift-workload-availability --ignore-not-found
oc delete operatorgroup --all -n openshift-workload-availability --ignore-not-found
oc delete subscription,csv,installplan --all -n openshift-kube-descheduler-operator --ignore-not-found
oc delete operatorgroup --all -n openshift-kube-descheduler-operator --ignore-not-found

# B — Stop root app from recreating children
oc patch application ocpvirt-workloads-ha-root -n openshift-gitops --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true

# C & D — Delete apps and clear finalizers
for app in ocpvirt-workloads-ha-config ocpvirt-workloads-ha-descheduler-config \
           ocpvirt-workloads-ha-install ocpvirt-workloads-ha-root \
           openshift-workload-operators-config openshift-workload-operators-descheduler-config \
           openshift-workload-operators-install openshift-workload-operators \
           operator-config-files-root; do
  oc delete application "${app}" -n openshift-gitops --ignore-not-found --wait=false
  oc patch application "${app}" -n openshift-gitops --type=merge \
    -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
done

oc get application -n openshift-gitops | grep -E 'ocpvirt|workload|operator-config' || echo "All apps deleted"
```

Then follow [Step 1](#step-1--push-repo-and-register-in-argocd) through
[Step 7](#step-7--confirm-phase-2-sync).

### Level 3 — Delete namespaces (nuclear)

Run Level 2 first, then:

```sh
oc delete namespace openshift-workload-availability --ignore-not-found
oc delete namespace openshift-kube-descheduler-operator --ignore-not-found
oc get namespace openshift-workload-availability openshift-kube-descheduler-operator
```

If a namespace is stuck in **Terminating**, check remaining finalizers:

```sh
oc get namespace openshift-workload-availability -o yaml | grep -A5 finalizers
```

### Verify clean state

```sh
oc get applications -n openshift-gitops
oc get subscription,csv -n openshift-workload-availability 2>/dev/null
oc get subscription,csv -n openshift-kube-descheduler-operator 2>/dev/null
oc get nodehealthcheck,selfnoderemediationtemplate -n openshift-workload-availability 2>/dev/null
oc get kubedescheduler cluster 2>/dev/null
oc get operatorgroup openshift-workload-availability -n openshift-workload-availability -o yaml 2>/dev/null | grep -A3 '^spec:'
```

Expected: no subscriptions, no CSVs, no config CRs (Level 1), or no applications
either (Level 2+). OperatorGroup `spec: {}` with no `targetNamespaces`.

## Day-to-day operations

Use these instead of the `argocd` CLI.

### Check Application status

```sh
oc get applications -n openshift-gitops
oc get application ocpvirt-workloads-ha-install ocpvirt-workloads-ha-config \
  -n openshift-gitops \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

### Sync an Application

Helper script (recommended):

```sh
./scripts/sync-application.sh ocpvirt-workloads-ha-config
FORCE=true ./scripts/sync-application.sh ocpvirt-workloads-ha-config
```

The `operation` field is **top-level** on the Application (not under `spec`).
Use `syncStrategy.hook` or `syncStrategy.apply` — not `revision` alone.

Manual equivalent:

```sh
APP=ocpvirt-workloads-ha-config
oc patch application "${APP}" -n openshift-gitops --type json \
  -p='[{"op":"remove","path":"/operation"}]' 2>/dev/null || true
oc patch application "${APP}" -n openshift-gitops --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
oc patch application "${APP}" -n openshift-gitops --type merge -p '{
  "operation": {
    "initiatedBy": {"username": "oc"},
    "sync": {"syncStrategy": {"hook": {}}}
  }
}'
```

### Apply config directly (bypass Argo CD)

When operators and CRDs are healthy but Argo CD will not sync:

```sh
./scripts/apply-workload-config.sh
# or
oc apply -k modules/ocpvirt-workloads-ha/overlays/config
```

### Open Argo CD UI (optional)

```sh
oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='https://{.spec.host}{"\n"}'
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| OwnNamespace InstallModeType not supported | OperatorGroup `targetNamespaces` set to install namespace | Use `spec: {}` in git; [Level 1 reset](#level-1-reset-operators-keep-argocd) on cluster |
| NodeHealthCheck / SNR template not found | Operator CRD not registered yet | [Approve InstallPlans in order](#installplan-approval-order); sync config app |
| Argo CD forbidden on config CRs | Missing Argo CD RBAC | `oc apply -f modules/ocpvirt-workloads-ha/argocd/rbac/ocpvirt-workloads-ha-argocd-rbac.yaml` |
| Config CRs Missing after CSVs Succeeded | Stuck sync or wrong patch format | [Apply config directly](#apply-config-directly-bypass-argocd) then sync |
| KubeDescheduler namespace missing | Cluster-scoped CR mixed with namespaced CRs | Use separate `ocpvirt-workloads-ha-descheduler-config` app (already in git) |
| KubeDescheduler validation error | `devLowNodeUtilizationThresholds` must be a string | Set to `Low`, `Medium`, or `High` in kube-descheduler-cluster.yaml |
| KubeDescheduler CRD missing | Descheduler InstallPlan not approved | Approve step 4 in [approval order](#installplan-approval-order) |
| Application will not delete | Root app recreates children / finalizers | [Level 2 reset](#level-2-full-reset-including-argocd-apps) |
| Argo CD cannot reach GitHub | Missing or wrong repo secret | Re-create secret per [Step 1](#step-1--push-repo-and-register-in-argocd) |

### OwnNamespace error (detail)

```
Operator failed
OwnNamespace InstallModeType not supported, cannot configure to watch own namespace
```

The node maintenance / remediation / health check operators require
**AllNamespaces** mode. Fix:
`modules/ocpvirt-workloads-ha/components/base-openshift-workload-availability/operatorgroup.yaml`
must use `spec: {}`.

### KubeDescheduler profileCustomizations validation (detail)

The upstream chart may render an object; the OpenShift API expects a string preset:

| Value | Underutilized | Overutilized |
|-------|---------------|--------------|
| `Low` | 10% | 30% |
| `Medium` | 20% | 50% (default) |
| `High` | 40% | 70% |

```yaml
profileCustomizations:
  devLowNodeUtilizationThresholds: Medium
```

### Config app stuck OutOfSync (detail)

```sh
./scripts/apply-workload-config.sh
./scripts/sync-application.sh ocpvirt-workloads-ha-config
oc get application ocpvirt-workloads-ha-config -n openshift-gitops \
  -o jsonpath='{.status.operationState.message}{"\n"}'
```

## Customization

Edit YAML under `modules/ocpvirt-workloads-ha/` directly. No Helm or extract step
is required for day-to-day changes.

### Local validation

```sh
kubectl kustomize modules/ocpvirt-workloads-ha/overlays/install
kubectl kustomize modules/ocpvirt-workloads-ha/overlays/config
kubectl kustomize modules/ocpvirt-workloads-ha/overlays/config-descheduler
kubectl kustomize modules/ocpvirt-workloads-ha
```

### Remediation backend

The default overlay uses `self-node-remediation-operator`. To swap backends,
edit `modules/ocpvirt-workloads-ha/overlays/config/kustomization.yaml` and replace
`../../components/self-node-remediation-operator/config` with one of:

- `../../components/fence-agents-remediation-operator/config`
- `../../components/machine-deletion-remediation-operator/config`

See `modules/ocpvirt-workloads-ha/overlays/remediation-backend.example.yaml`.
If you switch backends, update the `remediationTemplate` reference in the
NodeHealthCheck config.

### Site-specific edits

| File | Action |
|------|--------|
| `components/fence-agents-remediation-operator/config/secret-*.yaml` | Real BMC credentials |
| `components/fence-agents-remediation-operator/config/fence-agents-*.yaml` | Node IPMI parameters |
| `components/node-health-check-operator/config/node-health-check-*.yaml` | Narrow selector if needed |
| `components/kube-descheduler-operator/config/kube-descheduler-cluster.yaml` | Set `devLowNodeUtilizationThresholds` |
| `overlays/config/kustomization.yaml` | Pick remediation backend |

Paths are relative to `modules/ocpvirt-workloads-ha/`.

## Notes

- Subscriptions ignore OLM-managed `status` and `startingCSV` drift in Argo CD.
- Do not commit production secrets — use Sealed Secrets or External Secrets.
- `machine-deletion-remediation-operator` only applies on Machine API clusters.
- `kube-descheduler-operator` uses namespace `openshift-kube-descheduler-operator`.
