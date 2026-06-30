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

### Phase 2 — `clusters/ocp/config`

Argo CD Application: `openshift-workload-operators-config`

| Resource | Sync wave | Requires |
|----------|-----------|----------|
| `KubeDescheduler/cluster` | 5 | Descheduler operator CRD |
| `SelfNodeRemediationTemplate/self-node-remediation-resource-deletion-template` | 6 | Self-node-remediation operator CRD |
| `NodeHealthCheck/nhc-all-linux-nodes` | 7 | Node-health-check operator CRD + SNR template above |

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

### Prerequisites

```sh
# Logged in to your cluster
oc whoami

# OpenShift GitOps (Argo CD) installed
oc get ns openshift-gitops
oc get pods -n openshift-gitops
```

### Step 1 — Push repo to GitHub

```sh
cd /path/to/operator-config-files
git push origin main
```

Argo CD Applications use SSH: `git@github.com:ravishar-rh/operator-config-files.git`

Configure Argo CD with SSH access to GitHub before bootstrapping. Choose one
method below.

#### Option A — `oc` secret (no argocd CLI login required)

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

#### Option B — `argocd` CLI

The CLI must be logged in before `argocd repo add` works. `Argo CD server
address unspecified` means you skipped login.

```sh
# 1. Get the Argo CD route
ARGOCD_SERVER=$(oc get route openshift-gitops-server -n openshift-gitops \
  -o jsonpath='{.spec.host}')
echo "Argo CD server: ${ARGOCD_SERVER}"

# 2. Log in (pick one)

# SSO (if configured on your cluster)
argocd login "${ARGOCD_SERVER}" --sso --grpc-web

# Or admin password
argocd login "${ARGOCD_SERVER}" --username admin --password "$(
  oc get secret openshift-gitops-cluster -n openshift-gitops \
    -o jsonpath='{.data.admin\.password}' | base64 -d
)" --grpc-web

# 3. Add the repo
argocd repo add git@github.com:ravishar-rh/operator-config-files.git \
  --ssh-private-key-path "${HOME}/.ssh/id_ed25519" \
  --grpc-web
```

#### Option C — HTTPS instead of SSH

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
| `openshift-workload-operators-config` | `clusters/ocp/config` | Operator config CRs |

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

If still failing after all CSVs are Succeeded, force a sync:

```sh
argocd app sync openshift-workload-operators-config --force
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
        KubeDescheduler (wave 5)
        SelfNodeRemediationTemplate (wave 6)
        NodeHealthCheck (wave 7)
```

## Troubleshooting

### NodeHealthCheck / SelfNodeRemediationTemplate not found

The operator CRD is not registered yet. Check:

```sh
oc get installplan -n openshift-workload-availability
oc get csv -n openshift-workload-availability
oc get crd | rg -i 'nodehealth|selfnoderemediation|kubedescheduler'
```

Fix: approve InstallPlans in the order above, wait for CSV **Succeeded**, then
re-sync the config Application.

### Config app stuck OutOfSync

Hard refresh the config app in Argo CD UI, or:

```sh
argocd app sync openshift-workload-operators-config --force
```

### Argo CD cannot reach GitHub repo

`Argo CD server address unspecified` — run `argocd login` first (see Option B
in Step 1), or use the `oc create secret` method (Option A) instead.

Confirm the repo is registered:

```sh
oc get secret -n openshift-gitops -l argocd.argoproj.io/secret-type=repository
argocd repo list --grpc-web   # requires argocd login
```

For SSH, ensure the matching public key is added to GitHub as a deploy key or
account SSH key.

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
| `clusters/ocp/config/kustomization.yaml` | Pick remediation backend |

## Notes

- Subscriptions ignore OLM-managed `status` and `startingCSV` drift in Argo CD.
- Do not commit production secrets — use Sealed Secrets or External Secrets.
- `machine-deletion-remediation-operator` only applies on Machine API clusters.
- `kube-descheduler-operator` uses namespace `openshift-kube-descheduler-operator`.
