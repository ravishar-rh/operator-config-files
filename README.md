# operator-config-files

GitOps-ready OpenShift operator manifests for 

1. `node-maintenance`
2. `self-node-remediation` or `fence-agents-remediation` or `machine-deletion-remediation`
3. `node-health-check`
4. `descheduler`

. Argo CD deploys the cluster overlay at `clusters/ocp`.

Repository: https://github.com/ravishar-rh/operator-config-files

## Repository layout

```
.
├── argocd/applications/          # Argo CD Application CRs (bootstrap)
├── base/openshift-workload-availability/
│   ├── namespace.yaml            # Shared namespace (sync-wave 0)
│   └── operatorgroup.yaml        # Shared operator group (sync-wave 1)
├── clusters/ocp/                 # Cluster overlay — Argo CD deploy path
│   └── kustomization.yaml
├── node-maintenance-operator/    # Subscription only (sync-wave 2)
├── self-node-remediation-operator/
│   ├── install/subscription.yaml
│   └── config/                   # SelfNodeRemediationTemplate (sync-wave 6)
├── node-health-check-operator/
├── kube-descheduler-operator/    # Own namespace + install + config
├── fence-agents-remediation-operator/   # Optional — not in default overlay
└── machine-deletion-remediation-operator/ # Optional — not in default overlay
```

Sync order is enforced with `argocd.argoproj.io/sync-wave` annotations on each
resource. Config CRs use `SkipDryRunOnMissingResource=true` so Argo CD can sync
before operator CRDs exist.

## Default stack (clusters/ocp)

The default overlay deploys, in order:

1. Shared namespace and operator group
2. `node-maintenance-operator`
3. `self-node-remediation-operator` (+ remediation template)
4. `node-health-check-operator` (+ NodeHealthCheck)
5. `kube-descheduler-operator` (+ KubeDescheduler CR)

To use a different remediation backend, edit `clusters/ocp/kustomization.yaml`
and swap `self-node-remediation-operator` for `fence-agents-remediation-operator`
or `machine-deletion-remediation-operator`. See
`clusters/ocp/remediation-backend.example.yaml`.

## Argo CD bootstrap

Prerequisite: OpenShift GitOps (Argo CD) installed in `openshift-gitops`.

### Option A — App of Apps (recommended)

Apply the root Application once. It manages the child Application that deploys
the operator stack:

```sh
oc apply -f argocd/applications/root.yaml
```

### Option B — Direct Application

Apply only the workload operators Application:

```sh
oc apply -f argocd/applications/openshift-workload-operators.yaml
```

### After sync

1. Open the Argo CD UI and confirm `openshift-workload-operators` is synced.
2. Approve OLM InstallPlans manually (`installPlanApproval: Manual` on all
   subscriptions).
3. Wait for operator pods before config CRs reconcile (Argo CD retries with
   backoff; config CRs have sync-wave 6).

## Local validation

```sh
kubectl kustomize clusters/ocp
kubectl kustomize argocd/applications
```

## Regenerate from Helm charts

After editing upstream `values.yaml` in `~/Downloads/gitops`:

```sh
./extract.sh
git diff
git commit -am "Regenerate manifests from helm charts"
git push
```

Environment overrides:

- `GITOPS` — path to extracted charts (default: `~/Downloads/gitops`)
- `HELM` — path to the `helm` binary

## Site-specific edits before first push

| File | Action |
|------|--------|
| `fence-agents-remediation-operator/config/secret-*.yaml` | Set real BMC credentials |
| `fence-agents-remediation-operator/config/fence-agents-*.yaml` | Set node IPMI parameters |
| `node-health-check-operator/config/node-health-check-*.yaml` | Narrow selector if needed |
| `clusters/ocp/kustomization.yaml` | Pick remediation backend |

## Git workflow

1. Clone this repo and create a branch for site changes.
2. Edit cluster overlay and config files.
3. Validate with `kubectl kustomize clusters/ocp`.
4. Push to GitHub; Argo CD syncs from `targetRevision: main` (change in the
   Application CR if you use a different branch).
5. Do not commit real secrets — use Sealed Secrets, External Secrets, or
   OpenShift secrets injected outside Git for production credentials.

## Notes

- Subscriptions ignore OLM-managed `status` and `startingCSV` drift in Argo CD.
- `machine-deletion-remediation-operator` only applies on Machine API clusters.
- `kube-descheduler-operator` uses namespace `openshift-kube-descheduler-operator`.
