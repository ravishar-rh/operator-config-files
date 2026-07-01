# operator-config-files

GitOps-ready OpenShift Virtualization workload HA operators, packaged as the
**ocpvirt-workloads-ha** Kustomize module. Manifest fixes (config CRs, RBAC,
subscriptions, Application specs) are delivered via **git push** — Argo CD applies
them automatically. InstallPlan approval stays **Manual** (the one cluster
operation OLM cannot do from git).

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
└── scripts/                          # oc-only sync and InstallPlan helpers
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
Subscriptions use `installPlanApproval: Manual` with staggered sync-waves (2–5).
Argo CD creates the Subscription objects from git; you approve each InstallPlan
on the cluster (see [InstallPlan approval](#installplan-approval)).

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
| `ocpvirt-workloads-ha-root` | `argocd/applications` | App-of-Apps parent |
| `ocpvirt-workloads-ha-rbac` | `argocd/rbac` | Argo CD controller RBAC |
| `ocpvirt-workloads-ha-install` | `overlays/install` | OLM subscriptions (Manual InstallPlan) |
| `ocpvirt-workloads-ha-config` | `overlays/config` | Namespaced config CRs |
| `ocpvirt-workloads-ha-descheduler-config` | `overlays/config-descheduler` | Cluster-scoped KubeDescheduler (no `destination.namespace`) |

Paths are relative to `modules/ocpvirt-workloads-ha/`.

### Why multiple Argo CD Applications?

**Install vs config** — OLM subscriptions create InstallPlans and install CSVs
asynchronously. Operator CRDs are registered only after each CSV completes. If
config CRs sync in the same Application before CRDs exist, Argo CD reports
`Resource not found in cluster`. Config apps use `SkipDryRunOnMissingResource`,
unlimited retry, and `dependsOn` the install app so they converge automatically
once operators are ready.

**Config vs descheduler-config** — `KubeDescheduler` is cluster-scoped (no
namespace). It must be deployed by `ocpvirt-workloads-ha-descheduler-config`
which has **no** `destination.namespace`. Deploying it via the config app (which
sets `destination.namespace`) causes:

```
Namespace for cluster operator.openshift.io/v1, Kind=KubeDescheduler is missing.
```

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
| **GitOps work already done** | Install/config split, Manual InstallPlans, sync-waves, retry, RBAC and config via git push |
| **Runtime behavior** | Operator CRs behave the same regardless of which OLM generation installed them |
| **Support lifecycle** | Red Hat commits to Classic OLM support throughout OpenShift 4 |

Revisit OLM v1 when the cluster runs OpenShift 4.19+, Red Hat publishes
`ClusterExtension` manifests for this operator set, and each package is confirmed
compatible.

## Quick reference

### What git push handles (no `oc apply` needed)

After one-time bootstrap, commit and push to apply:

| Change in git | Argo CD Application |
|---------------|---------------------|
| Config CRs (NHC, SNR template, KubeDescheduler) | `ocpvirt-workloads-ha-config`, `ocpvirt-workloads-ha-descheduler-config` |
| Subscriptions, namespaces, OperatorGroups | `ocpvirt-workloads-ha-install` |
| Argo CD RBAC | `ocpvirt-workloads-ha-rbac` |
| Application CR fixes (paths, sync policy) | `ocpvirt-workloads-ha-root` → child apps |

All child apps use automated sync and selfHeal. Fix YAML, `git push`, Argo converges.

### What still requires cluster action

| Action | Why | How |
|--------|-----|-----|
| **InstallPlan approval** | OLM Manual mode — not controllable from git | `./scripts/approve-installplan.sh` |
| **One-time bootstrap** | Argo CD needs initial app-of-apps + repo secret | See [Deployment guide](#deployment-guide) |

### InstallPlan approval

Approve **one at a time**. Wait for each CSV to reach **Succeeded** before the next.

| Order | Subscription | Namespace |
|-------|--------------|-----------|
| 1 | `node-maintenance-operator` | `openshift-workload-availability` |
| 2 | `self-node-remediation` | `openshift-workload-availability` |
| 3 | `node-healthcheck-operator` | `openshift-workload-availability` |
| 4 | `cluster-kube-descheduler-operator` | `openshift-kube-descheduler-operator` |

```sh
./scripts/approve-installplan.sh        # all four in order
./scripts/approve-installplan.sh 2      # only step 2
```

The script resolves InstallPlan name and namespace from each Subscription
automatically.

### Deployment flow

```
git push
  → Argo CD syncs Applications, RBAC, subscriptions (Manual InstallPlans created)
    → You approve InstallPlans in order (cluster operation)
  → CSVs install, CRDs registered
    → Config apps retry until CRDs exist, then apply config CRs automatically
```

### One-time cluster bootstrap

```sh
# 1. Register git repo in Argo CD (see Deployment guide)
# 2. Bootstrap the app-of-apps
oc apply -f modules/ocpvirt-workloads-ha/argocd/applications/root.yaml
```

After bootstrap, manifest and config changes are **git push only**. RBAC is
synced by the `ocpvirt-workloads-ha-rbac` Application — no separate `oc apply`.

## Deployment guide

If a previous attempt failed, start with
[Recovery and cleanup](#recovery-and-cleanup) first.

### Prerequisites

OpenShift GitOps (Argo CD) must be installed and you must be logged in:

```sh
oc whoami
oc get ns openshift-gitops
oc get pods -n openshift-gitops
```

**Git push** applies all manifest changes (config CRs, RBAC, subscriptions,
Application specs) via Argo CD automated sync — no `oc apply -k` for module
content. The only recurring cluster operation is **InstallPlan approval** (OLM
Manual mode).

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

### Step 3 — Bootstrap (one time)

```sh
oc apply -f modules/ocpvirt-workloads-ha/argocd/applications/root.yaml
oc get applications -n openshift-gitops
```

This creates five child Applications: `rbac`, `install`, `config`,
`descheduler-config`, all with automated sync.

### Step 4 — Push and let Argo CD sync manifests

```sh
git push origin main
```

Argo CD applies subscriptions, RBAC, and config CRs from git. Subscriptions
create **pending** InstallPlans (Manual mode).

### Step 5 — Approve InstallPlans (cluster operation)

This is the one step OLM cannot do from git:

```sh
./scripts/approve-installplan.sh
```

Approve one at a time; the script waits for each CSV **Succeeded** before the
next. Step 2 (self-node-remediation) must complete before step 3.

Config apps retry until CRDs exist — **Missing** on config resources until
InstallPlans are approved is normal.

### Step 6 — Verify (optional)

```sh
oc get csv -n openshift-workload-availability
oc get csv -n openshift-kube-descheduler-operator
oc get selfnoderemediationtemplate,nodehealthcheck -n openshift-workload-availability
oc get kubedescheduler cluster
oc get applications -n openshift-gitops
```

### Ongoing changes

Edit YAML under `modules/ocpvirt-workloads-ha/`, commit, and `git push`. Argo CD
syncs automatically — no `oc apply` of module manifests.

New operator installs still need InstallPlan approval after push. Config-only
changes (NHC selectors, KubeDescheduler thresholds, remediation backend) apply
from git once operators and CRDs are in place.

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

Continue from [Step 5 — Approve InstallPlans](#step-5--approve-installplans-cluster-operation).

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
           ocpvirt-workloads-ha-install ocpvirt-workloads-ha-rbac \
           ocpvirt-workloads-ha-root \
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
[Step 5](#step-5--approve-installplans-cluster-operation).

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

### Normal workflow: git push

Edit manifests, commit, push. Argo CD automated sync and selfHeal apply changes.
No `oc apply -k` required for module content.

### InstallPlan approval (after push creates new subscriptions)

```sh
./scripts/approve-installplan.sh
```

### Check Application status

```sh
oc get applications -n openshift-gitops
oc get application ocpvirt-workloads-ha-install ocpvirt-workloads-ha-config \
  -n openshift-gitops \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

### Force sync (fallback only)

If selfHeal does not pick up a git change within a few minutes:

```sh
./scripts/sync-application.sh ocpvirt-workloads-ha-config
FORCE=true ./scripts/sync-application.sh ocpvirt-workloads-ha-config
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
| NodeHealthCheck / SNR template not found | CRD not registered — InstallPlans not approved yet | [Approve InstallPlans](#installplan-approval); config app retries automatically |
| KubeDescheduler not found | Descheduler CRD not registered yet | Approve step 4; descheduler-config app retries automatically |
| KubeDescheduler namespace missing | Wrong Application syncing cluster-scoped CR | Ensure only `ocpvirt-workloads-ha-descheduler-config` deploys KubeDescheduler (no `destination.namespace`) |
| KubeDescheduler validation error | `devLowNodeUtilizationThresholds` must be a string | Set to `Low`, `Medium`, or `High` in kube-descheduler-cluster.yaml |
| Argo CD forbidden on config CRs | RBAC app not synced | Confirm `ocpvirt-workloads-ha-rbac` is Synced |
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

### KubeDescheduler not found (detail)

```
Resource not found in cluster: operator.openshift.io/v1/KubeDescheduler:cluster
```

**Cause:** Descheduler operator CSV not installed yet — approve InstallPlan step 4.
Config app retries automatically once the CRD exists.

```sh
./scripts/approve-installplan.sh 4
```

If CSV is **Succeeded** but Argo CD still shows Missing, hard-refresh the app
(git push should also trigger selfHeal):

```sh
oc patch application ocpvirt-workloads-ha-descheduler-config -n openshift-gitops --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### KubeDescheduler namespace missing (detail)

```
Namespace for cluster operator.openshift.io/v1, Kind=KubeDescheduler is missing.
```

**Cause:** `KubeDescheduler` is being synced by an Application with
`destination.namespace` set (usually `ocpvirt-workloads-ha-config` or a legacy
app), instead of `ocpvirt-workloads-ha-descheduler-config`.

**Fix:** Push latest git and confirm Application paths:

```sh
oc get application -n openshift-gitops \
  -o custom-columns=NAME:.metadata.name,PATH:.spec.source.path,NS:.spec.destination.namespace \
  | grep -E 'NAME|ocpvirt'
```

`ocpvirt-workloads-ha-descheduler-config` must use path
`modules/ocpvirt-workloads-ha/overlays/config-descheduler` with **empty** DEST_NS.
Delete legacy `openshift-workload-operators-*` apps if present.

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

After InstallPlans are approved and CSVs are **Succeeded**, push your fix to git.
Argo CD selfHeal should apply it. If stuck, hard-refresh:

```sh
oc patch application ocpvirt-workloads-ha-config -n openshift-gitops --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

Scripts `./scripts/apply-workload-config.sh` and `./scripts/sync-application.sh`
are optional fallbacks only — not needed for normal git-push workflow.

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

- Subscriptions use `installPlanApproval: Manual` — approve InstallPlans on the cluster; everything else is git push.
- Config apps use unlimited retry; **Missing** status until CRDs exist is normal.
- Subscriptions ignore OLM-managed `status` and `startingCSV` drift in Argo CD.
- Do not commit production secrets — use Sealed Secrets or External Secrets.
- `machine-deletion-remediation-operator` only applies on Machine API clusters.
- `kube-descheduler-operator` uses namespace `openshift-kube-descheduler-operator`.
- `scripts/approve-installplan.sh` is for InstallPlan approval only; config/RBAC fixes do not need `oc apply`.
