# operator-config-files

GitOps-ready OpenShift operator manifests extracted from the NOV Helm charts in
`~/Downloads/gitops`. Argo CD deploys operator install and config in two phases.

Repository: https://github.com/ravishar-rh/operator-config-files

## Repository layout

```
.
├── argocd/applications/              # Argo CD Application CRs (bootstrap)
├── base/openshift-workload-availability/
├── clusters/ocp/
│   ├── install/                      # Phase 1: namespaces, OLM subscriptions
│   └── config/                       # Phase 2: operator CRs (after CRDs exist)
├── node-maintenance-operator/
├── self-node-remediation-operator/
├── node-health-check-operator/
├── kube-descheduler-operator/
├── fence-agents-remediation-operator/   # Optional — not in default overlay
├── machine-deletion-remediation-operator/ # Optional — not in default overlay
└── extract.sh
```

## What gets deployed

### Phase 1 — `clusters/ocp/install`

Argo CD Application: `openshift-workload-operators-install`

| Namespace | Subscription (operator package) |
|-----------|--------------------------------|
| `openshift-workload-availability` | `node-maintenance-operator` |
| `openshift-workload-availability` | `self-node-remediation` |
| `openshift-workload-availability` | `node-healthcheck-operator` |
| `openshift-kube-descheduler-operator` | `cluster-kube-descheduler-operator` |

Also creates shared Namespace and OperatorGroup resources (sync-waves 0 and 1).
The OperatorGroup uses `spec: {}` (AllNamespaces mode) — do not set
`targetNamespaces` to the same namespace or operator installs will fail.

### Phase 2 — config CRs (two Argo CD Applications)

`KubeDescheduler` is **cluster-scoped** (no namespace). Argo CD cannot deploy it
in the same Application as namespaced CRs without reporting
`InvalidSpecError: Namespace ... is missing`. Config is split into two apps:

| Application | Path | Resources |
|-------------|------|-----------|
| `openshift-workload-operators-config` | `clusters/ocp/config` | SelfNodeRemediationTemplate, NodeHealthCheck |
| `openshift-workload-operators-descheduler-config` | `clusters/ocp/config-descheduler` | KubeDescheduler/cluster (cluster-scoped) |

**Workload config** (`clusters/ocp/config`):

| Resource | Sync wave | Requires |
|----------|-----------|----------|
| `SelfNodeRemediationTemplate/self-node-remediation-resource-deletion-template` | 6 | Self-node-remediation operator CRD |
| `NodeHealthCheck/nhc-all-linux-nodes` | 7 | Node-health-check operator CRD + SNR template above |

**Descheduler config** (`clusters/ocp/config-descheduler`):

| Resource | Sync wave | Requires |
|----------|-----------|----------|
| `KubeDescheduler/cluster` | 8 | Kube descheduler operator CRD |

## Why two Argo CD Applications?

OLM subscriptions (sync-wave 2) only create InstallPlans. Operator CRDs such as
`NodeHealthCheck` are registered only after you approve InstallPlans and the CSV
install completes. If config CRs sync in the same Application, Argo CD reports:

```
Resource not found in cluster: remediation.medik8s.io/v1alpha1/NodeHealthCheck:nhc-all-linux-nodes
```

Phase 1 applies subscriptions. Phase 2 applies config CRs after phase 1 syncs,
with unlimited retry until CRDs exist.

## Deployment guide

If a previous attempt failed, start with
[Clean up and restart from scratch](#clean-up-and-restart-from-scratch) first.

### Prerequisites

```sh
# Logged in to your cluster
oc whoami

# OpenShift GitOps (Argo CD) installed
oc get ns openshift-gitops
oc get pods -n openshift-gitops
```

Grant the Argo CD application controller permission to create operator config
CRs (required once per cluster):

```sh
oc apply -f argocd/rbac/workload-operators-argocd-rbac.yaml

# Verify permission
oc auth can-i patch selfnoderemediationtemplates \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller \
  -n openshift-workload-availability
# Expected: yes
```

### Step 1 — Push repo to GitHub

```sh
cd /path/to/operator-config-files
git push origin main
```

Argo CD Applications use SSH: `git@github.com:ravishar-rh/operator-config-files.git`

Configure Argo CD with GitHub access before bootstrapping. All steps below use
`oc` only — no local `argocd` CLI required.

#### SSH (recommended)

Add your SSH public key as a deploy key on GitHub first:
https://github.com/ravishar-rh/operator-config-files/settings/keys → **Add deploy key**
(read-only is sufficient).

Then register the repo in Argo CD:

```sh
oc create secret generic repo-operator-config-files \
  -n openshift-gitops \
  --from-literal=type=git \
  --from-literal=url=git@github.com:ravishar-rh/operator-config-files.git \
  --from-file=sshPrivateKey="${HOME}/.ssh/id_ed25519"

oc label secret repo-operator-config-files \
  -n openshift-gitops \
  argocd.argoproj.io/secret-type=repository
```

Verify Argo CD picked up the repo (may take a few seconds):

```sh
oc get secret -n openshift-gitops -l argocd.argoproj.io/secret-type=repository
```

#### HTTPS instead of SSH

Change `repoURL` in the Application CRs to HTTPS, or use a GitHub personal
access token via an `oc` secret:

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

### Step 2 — Remove old Application (if upgrading)

If you previously deployed the single-app layout:

```sh
oc delete application openshift-workload-operators -n openshift-gitops --ignore-not-found
```

### Step 3 — Bootstrap Argo CD Applications

```sh
oc apply -f argocd/applications/root.yaml
```

This creates:

| Application | Path | Purpose |
|-------------|------|---------|
| `operator-config-files-root` | `argocd/applications` | App-of-Apps parent |
| `openshift-workload-operators-install` | `clusters/ocp/install` | OLM subscriptions |
| `openshift-workload-operators-config` | `clusters/ocp/config` | Workload operator config CRs |
| `openshift-workload-operators-descheduler-config` | `clusters/ocp/config-descheduler` | KubeDescheduler (cluster-scoped) |

Verify:

```sh
oc get applications -n openshift-gitops
```

### Step 4 — Confirm Phase 1 sync

The install app uses automated sync. Confirm it is **Synced/Healthy**:

```sh
oc get application openshift-workload-operators-install -n openshift-gitops
oc get subscription -n openshift-workload-availability
oc get subscription -n openshift-kube-descheduler-operator
```

Pending InstallPlans should appear:

```sh
oc get installplan -n openshift-workload-availability
oc get installplan -n openshift-kube-descheduler-operator
```

### Step 5 — Approve InstallPlans (in order)

All subscriptions use `installPlanApproval: Manual`. Approve **one at a time**
and wait for each CSV to reach **Succeeded** before approving the next.

Do not approve all InstallPlans at once. Config CRs need operator CRDs first —
especially `self-node-remediation` before `node-healthcheck-operator`, because
`NodeHealthCheck` references the `SelfNodeRemediationTemplate`.

#### 1. Node Maintenance Operator

```sh
oc get installplan -n openshift-workload-availability

oc patch installplan <installplan-name> -n openshift-workload-availability \
  --type merge -p '{"spec":{"approved":true}}'

oc get csv -n openshift-workload-availability | grep node-maintenance
watch oc get csv -n openshift-workload-availability
```

Wait until the node-maintenance CSV shows **Succeeded**.

#### 2. Self Node Remediation Operator

Required before the remediation template and NodeHealthCheck config.

```sh
oc get installplan -n openshift-workload-availability

oc patch installplan <installplan-name> -n openshift-workload-availability \
  --type merge -p '{"spec":{"approved":true}}'

oc get csv -n openshift-workload-availability | grep self-node-remediation
```

Wait until the self-node-remediation CSV shows **Succeeded**.

#### 3. Node Health Check Operator

```sh
oc get installplan -n openshift-workload-availability

oc patch installplan <installplan-name> -n openshift-workload-availability \
  --type merge -p '{"spec":{"approved":true}}'

oc get csv -n openshift-workload-availability | grep node-healthcheck
```

Wait until the node-healthcheck CSV shows **Succeeded**.

#### 4. Kube Descheduler Operator

Separate namespace. Can run after step 1; safest to approve last.

```sh
oc get installplan -n openshift-kube-descheduler-operator

oc patch installplan <installplan-name> -n openshift-kube-descheduler-operator \
  --type merge -p '{"spec":{"approved":true}}'

oc get csv -n openshift-kube-descheduler-operator
```

Wait until the descheduler CSV shows **Succeeded**.

### Step 6 — Verify CRDs exist

Before Phase 2 can succeed, confirm CRDs are registered:

```sh
oc get crd selfnoderemediationtemplates.self-node-remediation.medik8s.io
oc get crd nodehealthchecks.remediation.medik8s.io
oc get crd kubedeschedulers.operator.openshift.io
```

All should exist and be **Established**.

### Step 7 — Confirm Phase 2 sync

The config app depends on the install app and retries until CRDs exist.

```sh
oc get application openshift-workload-operators-config -n openshift-gitops
```

If still failing after all CSVs are Succeeded:

```sh
./scripts/apply-workload-config.sh
# or
./scripts/sync-application.sh openshift-workload-operators-config
```

Verify config resources:

```sh
oc get selfnoderemediationtemplate -n openshift-workload-availability
oc get nodehealthcheck -n openshift-workload-availability
oc get kubedescheduler cluster
```

### Deployment flow

```
Apply root.yaml
  → Install app syncs subscriptions
    → Approve: node-maintenance-operator (wait for CSV Succeeded)
    → Approve: self-node-remediation (wait for CSV Succeeded)
    → Approve: node-healthcheck-operator (wait for CSV Succeeded)
    → Approve: cluster-kube-descheduler-operator (wait for CSV Succeeded)
  → All CRDs Established
    → Config app syncs:
        SelfNodeRemediationTemplate (wave 6)
        NodeHealthCheck (wave 7)
        KubeDescheduler (wave 8)
```

## Clean up and restart from scratch

Use this when operators are stuck in **Failed**, InstallPlans were approved in
the wrong order, the OperatorGroup is misconfigured, or config CRs will not sync.
All commands use `oc` only.

Clone or `cd` to this repo on a machine with cluster access before running the
`oc apply` steps below.

### When to use which reset

| Situation | Reset level |
|-----------|-------------|
| One CSV failed, others fine | [Level 1 — operators only](#level-1-reset-operators-keep-argocd) |
| OwnNamespace / OperatorGroup error | [Level 1](#level-1-reset-operators-keep-argocd) |
| Multiple failed CSVs, bad InstallPlan order | [Level 1](#level-1-reset-operators-keep-argocd) |
| Argo CD apps OutOfSync / stuck operations | [Level 2 — full reset](#level-2-full-reset-including-argocd-apps) |
| Namespaces corrupted or want completely clean slate | [Level 3 — delete namespaces](#level-3-delete-namespaces-nuclear) |

---

### Level 1 — Reset operators (keep Argo CD)

Removes OLM state and config CRs. Keeps Argo CD Applications, namespaces, and
OperatorGroups. Use this for most recovery scenarios.

```sh
# --- Phase 2: config CRs ---
oc delete nodehealthcheck --all -n openshift-workload-availability --ignore-not-found
oc delete selfnoderemediationtemplate --all -n openshift-workload-availability --ignore-not-found
oc delete kubedescheduler cluster --ignore-not-found

# --- Phase 1: OLM (workload-availability namespace) ---
oc delete subscription --all -n openshift-workload-availability
oc delete csv --all -n openshift-workload-availability
oc delete installplan --all -n openshift-workload-availability

# --- Phase 1: OLM (descheduler namespace) ---
oc delete subscription --all -n openshift-kube-descheduler-operator
oc delete csv --all -n openshift-kube-descheduler-operator
oc delete installplan --all -n openshift-kube-descheduler-operator

# --- Fix OperatorGroup (AllNamespaces mode — required for these operators) ---
oc delete operatorgroup openshift-workload-availability -n openshift-workload-availability --ignore-not-found
oc apply -f base/openshift-workload-availability/operatorgroup.yaml

# --- Re-sync from git ---
./scripts/sync-application.sh openshift-workload-operators-install
```

Then continue from [Step 5 — Approve InstallPlans](#step-5--approve-installplans-in-order).

---

### Level 2 — Full reset (including Argo CD apps)

Deletes Argo CD Applications and all operator resources, then redeploys from git.
Use when Argo CD itself is stuck or Level 1 did not clear the failure.

**Why simple `oc delete application` often fails:**

1. **App-of-apps recreates child apps** — `operator-config-files-root` has
   `automated: selfHeal: true`. Delete a child app and the root app immediately
   recreates it from git.
2. **Finalizers block deletion** — all apps use
   `resources-finalizer.argocd.argoproj.io`. Argo CD will not remove an
   Application until its managed resources are gone (or finalizers are cleared).
3. **Apps stuck in Terminating** — remove finalizers manually (step 4 below).

Follow these steps **in order**:

```sh
# --- Step A: Delete managed resources FIRST (releases app finalizers) ---
oc delete nodehealthcheck --all -n openshift-workload-availability --ignore-not-found
oc delete selfnoderemediationtemplate --all -n openshift-workload-availability --ignore-not-found
oc delete kubedescheduler cluster --ignore-not-found

oc delete subscription --all -n openshift-workload-availability --ignore-not-found
oc delete csv --all -n openshift-workload-availability --ignore-not-found
oc delete installplan --all -n openshift-workload-availability --ignore-not-found
oc delete operatorgroup --all -n openshift-workload-availability --ignore-not-found

oc delete subscription --all -n openshift-kube-descheduler-operator --ignore-not-found
oc delete csv --all -n openshift-kube-descheduler-operator --ignore-not-found
oc delete installplan --all -n openshift-kube-descheduler-operator --ignore-not-found
oc delete operatorgroup --all -n openshift-kube-descheduler-operator --ignore-not-found

# --- Step B: Stop root app from recreating child apps ---
oc patch application operator-config-files-root -n openshift-gitops --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true

# --- Step C: Delete child apps, then root app ---
oc delete application openshift-workload-operators-config -n openshift-gitops --ignore-not-found --wait=false
oc delete application openshift-workload-operators-descheduler-config -n openshift-gitops --ignore-not-found --wait=false
oc delete application openshift-workload-operators-install -n openshift-gitops --ignore-not-found --wait=false
oc delete application openshift-workload-operators -n openshift-gitops --ignore-not-found --wait=false
oc delete application operator-config-files-root -n openshift-gitops --ignore-not-found --wait=false

# --- Step D: Force-remove finalizers if any app is stuck Terminating ---
for app in openshift-workload-operators-config \
           openshift-workload-operators-descheduler-config \
           openshift-workload-operators-install \
           openshift-workload-operators \
           operator-config-files-root; do
  oc patch application "${app}" -n openshift-gitops --type=merge \
    -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
done

# --- Step E: Verify all apps are gone ---
oc get application -n openshift-gitops | grep -E 'workload|operator-config' || echo "All apps deleted"
```

If step D still leaves apps behind, check what is blocking:

```sh
oc get application -n openshift-gitops
oc get application operator-config-files-root -n openshift-gitops -o yaml | tail -30
```

Then continue from [Fresh deploy checklist](#fresh-deploy-checklist).

---

### Level 3 — Delete namespaces (nuclear)

Removes everything including namespaces. Only use when namespaces are corrupted
or you need a completely empty starting point. **This removes all resources in
those namespaces.**

```sh
# Run Level 2 first (delete Argo CD apps + OLM resources)
# Then delete namespaces:
oc delete namespace openshift-workload-availability --ignore-not-found
oc delete namespace openshift-kube-descheduler-operator --ignore-not-found

# Wait for namespaces to terminate
oc get namespace openshift-workload-availability openshift-kube-descheduler-operator
```

If a namespace is stuck in **Terminating**, check for remaining finalizers:

```sh
oc get namespace openshift-workload-availability -o yaml | grep -A5 finalizers
```

Then continue from [Fresh deploy checklist](#fresh-deploy-checklist).

---

### Fresh deploy checklist

After any reset level, follow these steps in order:

```sh
# 1. Confirm git repo is registered in Argo CD
oc get secret -n openshift-gitops -l argocd.argoproj.io/secret-type=repository

# 2. Bootstrap Argo CD Applications (from repo checkout)
oc apply -f argocd/applications/root.yaml

# 3. Wait for install app to sync
watch oc get application openshift-workload-operators-install -n openshift-gitops \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# 4. Confirm subscriptions exist
oc get subscription -n openshift-workload-availability
oc get subscription -n openshift-kube-descheduler-operator

# 5. Approve InstallPlans ONE AT A TIME (see Step 5 below)
# 6. Verify CRDs exist (Step 6)
# 7. Sync config app (Step 7)
```

**InstallPlan approval order** (wait for CSV **Succeeded** between each):

| Order | Operator | Namespace |
|-------|----------|-----------|
| 1 | `node-maintenance-operator` | `openshift-workload-availability` |
| 2 | `self-node-remediation` | `openshift-workload-availability` |
| 3 | `node-healthcheck-operator` | `openshift-workload-availability` |
| 4 | `cluster-kube-descheduler-operator` | `openshift-kube-descheduler-operator` |

```sh
# Approve one plan at a time:
oc get installplan -n openshift-workload-availability
oc patch installplan <installplan-name> -n openshift-workload-availability \
  --type merge -p '{"spec":{"approved":true}}'
watch oc get csv -n openshift-workload-availability
```

---

### Verify clean state before redeploying

```sh
echo "=== Argo CD ==="
oc get applications -n openshift-gitops

echo "=== Subscriptions ==="
oc get subscription -n openshift-workload-availability 2>/dev/null
oc get subscription -n openshift-kube-descheduler-operator 2>/dev/null

echo "=== CSVs ==="
oc get csv -n openshift-workload-availability 2>/dev/null
oc get csv -n openshift-kube-descheduler-operator 2>/dev/null

echo "=== Config CRs ==="
oc get nodehealthcheck,selfnoderemediationtemplate -n openshift-workload-availability 2>/dev/null
oc get kubedescheduler cluster 2>/dev/null

echo "=== OperatorGroup (workload — spec must be empty for AllNamespaces) ==="
oc get operatorgroup openshift-workload-availability -n openshift-workload-availability -o yaml 2>/dev/null | grep -A3 '^spec:'
```

Expected before fresh deploy: no subscriptions, no CSVs, no config CRs (Level 1),
or no applications either (Level 2+). OperatorGroup `spec: {}` with no
`targetNamespaces`.

## OpenShift GitOps helpers (`oc` only)

Use these instead of the `argocd` CLI for common operations.

### Check Application status

```sh
oc get applications -n openshift-gitops

oc get application openshift-workload-operators-install -n openshift-gitops \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

oc get application openshift-workload-operators-config -n openshift-gitops \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

### Refresh an Application (pull latest git commit)

```sh
APP=openshift-workload-operators-config

oc patch application "${APP}" -n openshift-gitops --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Sync an Application (correct `oc` method)

The `operation` field is **top-level** on the Application (not under `spec`).
Use `syncStrategy.hook` or `syncStrategy.apply` — not `revision` alone.

Helper script (recommended):

```sh
./scripts/sync-application.sh openshift-workload-operators-config
FORCE=true ./scripts/sync-application.sh openshift-workload-operators-config
```

Manual equivalent:

```sh
APP=openshift-workload-operators-config

# Clear stuck operation from a previous failed sync
oc patch application "${APP}" -n openshift-gitops --type json \
  -p='[{"op":"remove","path":"/operation"}]' 2>/dev/null || true

oc patch application "${APP}" -n openshift-gitops --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

oc patch application "${APP}" -n openshift-gitops --type merge -p '{
  "operation": {
    "initiatedBy": {"username": "oc"},
    "sync": {
      "syncStrategy": {"hook": {}}
    }
  }
}'
```

Check result:

```sh
oc get application "${APP}" -n openshift-gitops \
  -o jsonpath='sync={.status.sync.status} health={.status.health.status} op={.status.operationState.phase}{"\n"}message={.status.operationState.message}{"\n"}'
```

### Force sync (when resources are stuck OutOfSync)

```sh
FORCE=true ./scripts/sync-application.sh openshift-workload-operators-config
```

Or manually:

```sh
APP=openshift-workload-operators-config

oc patch application "${APP}" -n openshift-gitops --type json \
  -p='[{"op":"remove","path":"/operation"}]' 2>/dev/null || true

oc patch application "${APP}" -n openshift-gitops --type merge -p '{
  "operation": {
    "initiatedBy": {"username": "oc"},
    "sync": {
      "syncStrategy": {"apply": {"force": true}}
    }
  }
}'
```

### Bypass Argo CD — apply config directly with `oc`

When operators and CRDs are healthy but Argo CD will not sync, apply from git
then refresh the app:

```sh
./scripts/apply-workload-config.sh
```

Or manually:

```sh
oc apply -k clusters/ocp/config
oc get selfnoderemediationtemplate,nodehealthcheck -n openshift-workload-availability
```

### Open Argo CD UI in browser (optional)

```sh
oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='https://{.spec.host}{"\n"}'
```

## Troubleshooting

### OwnNamespace InstallModeType not supported

```
Operator failed
OwnNamespace InstallModeType not supported, cannot configure to watch own namespace
```

**Cause:** The OperatorGroup had `targetNamespaces` set to the same namespace
(`openshift-workload-availability`). OLM interprets that as **OwnNamespace**
install mode, but the node maintenance / remediation / health check operators
require **AllNamespaces** mode.

**Fix in git:** `base/openshift-workload-availability/operatorgroup.yaml` uses
`spec: {}` (no `targetNamespaces`).

**Fix on cluster:** follow [Level 1 — Reset operators](#level-1-reset-operators-keep-argocd).

### NodeHealthCheck / SelfNodeRemediationTemplate not found

The operator CRD is not registered yet. Check:

```sh
oc get installplan -n openshift-workload-availability
oc get csv -n openshift-workload-availability
oc get crd | grep -iE 'nodehealth|selfnoderemediation|kubedescheduler'
```

Fix: approve InstallPlans in the order above, wait for CSV **Succeeded**, then
sync using [Sync an Application](#sync-an-application-correct-oc-method) or
[apply config directly](#bypass-argocd--apply-config-directly-with-oc).

### Argo CD forbidden — cannot patch operator config CRs

```
User "system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller"
cannot patch resource "selfnoderemediationtemplates" ...
```

**Cause:** OpenShift GitOps application controller lacks RBAC for Medik8s/OpenShift
operator config CRDs.

**Fix:**

```sh
oc apply -f argocd/rbac/workload-operators-argocd-rbac.yaml

oc auth can-i patch selfnoderemediationtemplates \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller \
  -n openshift-workload-availability

./scripts/sync-application.sh openshift-workload-operators-config
```

### Config CRs still Missing after CSVs Succeeded

Operators and CRDs are ready but Argo CD shows **OutOfSync / Missing**. This
usually means a previous sync failed and the `operation` field is stuck, or the
sync patch format was wrong.

**Step 1 — confirm CRDs and CSVs (you already have these):**

```sh
oc get csv -n openshift-workload-availability
oc get crd selfnoderemediationtemplates.self-node-remediation.medik8s.io
oc get crd nodehealthchecks.remediation.medik8s.io
```

**Step 2 — apply config directly (fastest fix):**

```sh
cd ~/Development/operator-config-files
./scripts/apply-workload-config.sh
```

**Step 3 — if direct apply fails, capture the real error:**

```sh
oc apply -k clusters/ocp/config
```

**Step 4 — if direct apply works but Argo CD stays OutOfSync, trigger sync:**

```sh
./scripts/sync-application.sh openshift-workload-operators-config
```

**Step 5 — read Argo CD failure message if sync still fails:**

```sh
oc get application openshift-workload-operators-config -n openshift-gitops \
  -o jsonpath='{.status.operationState.message}{"\n"}'
oc get application openshift-workload-operators-config -n openshift-gitops -o yaml | tail -40
```

### KubeDescheduler InvalidSpecError (namespace missing)

```
InvalidSpecError
Namespace for cluster operator.openshift.io/v1, Kind=KubeDescheduler is missing.
```

**Cause:** `KubeDescheduler` is cluster-scoped (no `metadata.namespace`). Argo CD
cannot mix it with namespaced CRs in one Application.

**Fix in git:** descheduler config is in a separate path
(`clusters/ocp/config-descheduler`) and Application
(`openshift-workload-operators-descheduler-config`).

**Fix on cluster** — pull latest git, refresh root app, then sync:

```sh
./scripts/sync-application.sh operator-config-files-root
oc get application openshift-workload-operators-descheduler-config -n openshift-gitops
```

Or apply directly while waiting for git sync:

```sh
oc apply -f kube-descheduler-operator/config/kube-descheduler-cluster.yaml
```

### KubeDescheduler profileCustomizations validation error

```
spec.profileCustomizations.devLowNodeUtilizationThresholds: must be of type string
Supported values: "Low", "Medium", "High", ""
```

**Cause:** The upstream helm chart rendered an object (`thresholds`/`targetThresholds`).
The OpenShift API expects a **string preset**:

| Value | Underutilized | Overutilized |
|-------|---------------|--------------|
| `Low` | 10% | 30% |
| `Medium` | 20% | 50% (default) |
| `High` | 40% | 70% |

**Fix:** use a string in `kube-descheduler-operator/config/kube-descheduler-cluster.yaml`:

```yaml
profileCustomizations:
  devLowNodeUtilizationThresholds: Medium   # or Low, High
```

### KubeDescheduler not found (CRD missing)

Same root cause — the descheduler operator CRD is not registered yet. This
usually means InstallPlan step 4 was skipped or the CSV is still installing.

```sh
oc get installplan -n openshift-kube-descheduler-operator
oc get csv -n openshift-kube-descheduler-operator
oc get crd kubedeschedulers.operator.openshift.io
```

Fix:

```sh
# Approve the descheduler InstallPlan if still pending
oc patch installplan <installplan-name> -n openshift-kube-descheduler-operator \
  --type merge -p '{"spec":{"approved":true}}'

# Wait for CSV Succeeded, then sync descheduler config
watch oc get csv -n openshift-kube-descheduler-operator
oc apply -f kube-descheduler-operator/config/kube-descheduler-cluster.yaml
./scripts/sync-application.sh openshift-workload-operators-descheduler-config
```

The config app retries automatically, but only succeeds once the descheduler
CSV completes and the CRD is **Established**.

### Config app stuck OutOfSync

Use the force sync commands from [OpenShift GitOps helpers](#openshift-gitops-helpers-oc-only), or open the Argo CD UI:

```sh
oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='https://{.spec.host}{"\n"}'
```

### Argo CD Application will not delete

**Symptom:** `oc delete application` hangs, app shows **Terminating**, or the
app reappears immediately after deletion.

**Cause 1 — Root app recreates it:** disable automation on the root app first:

```sh
oc patch application operator-config-files-root -n openshift-gitops --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

**Cause 2 — Finalizer waiting on managed resources:** delete OLM resources first
(see [Level 2 Step A](#level-2-full-reset-including-argocd-apps)), then delete
the Application.

**Cause 3 — Stuck finalizer:** force clear and verify:

```sh
APP=openshift-workload-operators-install   # repeat for each stuck app

oc delete application "${APP}" -n openshift-gitops --wait=false
oc patch application "${APP}" -n openshift-gitops --type=merge \
  -p '{"metadata":{"finalizers":null}}'
oc get application "${APP}" -n openshift-gitops 2>&1 || echo "deleted"
```

Delete all operator-config-files apps:

```sh
oc patch application operator-config-files-root -n openshift-gitops --type=json \
  -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>/dev/null || true

for app in openshift-workload-operators-config \
           openshift-workload-operators-descheduler-config \
           openshift-workload-operators-install \
           openshift-workload-operators \
           operator-config-files-root; do
  oc delete application "${app}" -n openshift-gitops --wait=false 2>/dev/null || true
  oc patch application "${app}" -n openshift-gitops --type=merge \
    -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
done

oc get application -n openshift-gitops
```

### Argo CD cannot reach GitHub repo

Confirm the repo secret exists and has the correct label:

```sh
oc get secret -n openshift-gitops -l argocd.argoproj.io/secret-type=repository
oc get secret repo-operator-config-files -n openshift-gitops -o yaml
```

For SSH, ensure the matching public key is added to GitHub as a deploy key or
account SSH key. Re-create the secret using the SSH steps in Step 1 if needed.

## Remediation backend

The default overlay uses `self-node-remediation-operator`. To swap backends,
edit `clusters/ocp/config/kustomization.yaml` and replace
`self-node-remediation-operator/config` with one of:

- `fence-agents-remediation-operator/config`
- `machine-deletion-remediation-operator/config`

See `clusters/ocp/remediation-backend.example.yaml` for details. If you switch
backends, update the `remediationTemplate` reference in the NodeHealthCheck
config to match.

## Local validation

```sh
kubectl kustomize clusters/ocp/install
kubectl kustomize clusters/ocp/config
kubectl kustomize clusters/ocp          # full stack (local only)
```

## Regenerate from Helm charts

After editing upstream `values.yaml` in `~/Downloads/gitops`:

```sh
./extract.sh
```

Environment overrides:

- `GITOPS` — path to extracted charts (default: `~/Downloads/gitops`)
- `HELM` — path to the `helm` binary

## Site-specific edits

| File | Action |
|------|--------|
| `fence-agents-remediation-operator/config/secret-*.yaml` | Real BMC credentials |
| `fence-agents-remediation-operator/config/fence-agents-*.yaml` | Node IPMI parameters |
| `node-health-check-operator/config/node-health-check-*.yaml` | Narrow selector if needed |
| `kube-descheduler-operator/config/kube-descheduler-cluster.yaml` | Set `devLowNodeUtilizationThresholds` to `Low`, `Medium`, or `High` |
| `clusters/ocp/config/kustomization.yaml` | Pick remediation backend |

## Notes

- Subscriptions ignore OLM-managed `status` and `startingCSV` drift in Argo CD.
- Do not commit production secrets — use Sealed Secrets or External Secrets.
- `machine-deletion-remediation-operator` only applies on Machine API clusters.
- `kube-descheduler-operator` uses namespace `openshift-kube-descheduler-operator`.
