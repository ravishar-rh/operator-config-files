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
└── extract.sh
```

## Why two Argo CD Applications?

OLM subscriptions (sync-wave 2) only create InstallPlans. Operator CRDs such as
`NodeHealthCheck` are registered only after you approve InstallPlans and the CSV
install completes. If config CRs sync in the same Application, Argo CD reports:

```
Resource not found in cluster: remediation.medik8s.io/v1alpha1/NodeHealthCheck:nhc-all-linux-nodes
```

Phase 1 (`openshift-workload-operators-install`) applies subscriptions.
Phase 2 (`openshift-workload-operators-config`) applies config CRs after phase 1
syncs, with unlimited retry until CRDs exist.

## Default stack

**Install** (`clusters/ocp/install`):

- Shared namespace + operator group
- Subscriptions: node-maintenance, self-node-remediation, node-health-check,
  kube-descheduler

**Config** (`clusters/ocp/config`):

- SelfNodeRemediationTemplate (sync-wave 6)
- NodeHealthCheck (sync-wave 7)
- KubeDescheduler CR (sync-wave 5)

## Argo CD bootstrap

Prerequisite: OpenShift GitOps (Argo CD) in `openshift-gitops`.

```sh
oc apply -f argocd/applications/root.yaml
```

This creates:

| Application | Path | Purpose |
|-------------|------|---------|
| `openshift-workload-operators-install` | `clusters/ocp/install` | OLM subscriptions |
| `openshift-workload-operators-config` | `clusters/ocp/config` | Operator config CRs |

If upgrading from the single-app layout, delete the old Application first:

```sh
oc delete application openshift-workload-operators -n openshift-gitops
oc apply -f argocd/applications/root.yaml
```

## Deployment workflow

1. **Sync install app** — confirm subscriptions exist in Argo CD.
2. **Approve InstallPlans** (required — subscriptions use `Manual` approval):

   ```sh
   oc get installplan -n openshift-workload-availability
   oc patch installplan <name> -n openshift-workload-availability \
     --type merge -p '{"spec":{"approved":true}}'
   ```

   Repeat for `openshift-kube-descheduler-operator` if needed.

3. **Wait for operators**:

   ```sh
   oc get csv -n openshift-workload-availability
   oc get crd nodehealthchecks.remediation.medik8s.io
   oc get crd selfnoderemediationtemplates.self-node-remediation.medik8s.io
   ```

4. **Sync config app** — Argo CD retries automatically; or click Sync on
   `openshift-workload-operators-config` once CRDs show `Established`.

## Troubleshooting

### NodeHealthCheck / SelfNodeRemediationTemplate not found

The operator CRD is not registered yet. Check:

```sh
# InstallPlan still pending?
oc get installplan -n openshift-workload-availability

# CSV not yet succeeded?
oc get csv -n openshift-workload-availability

# CRD missing?
oc get crd | rg -i 'nodehealth|selfnoderemediation|kubedescheduler'
```

Fix: approve InstallPlans, wait for CSV `Succeeded`, then re-sync the config
Application.

### Config app stuck OutOfSync

Hard refresh the config app in Argo CD UI, or:

```sh
argocd app sync openshift-workload-operators-config --force
```

## Remediation backend

Edit `clusters/ocp/config/kustomization.yaml` to swap remediation operators.
See `clusters/ocp/remediation-backend.example.yaml`.

## Local validation

```sh
kubectl kustomize clusters/ocp/install
kubectl kustomize clusters/ocp/config
kubectl kustomize clusters/ocp          # full stack (local only)
```

## Regenerate from Helm charts

```sh
./extract.sh
```

## Site-specific edits

| File | Action |
|------|--------|
| `fence-agents-remediation-operator/config/secret-*.yaml` | Real BMC credentials |
| `node-health-check-operator/config/node-health-check-*.yaml` | Narrow selector if needed |
| `clusters/ocp/config/kustomization.yaml` | Pick remediation backend |

## Notes

- Subscriptions ignore OLM-managed `status` and `startingCSV` drift in Argo CD.
- Do not commit production secrets — use Sealed Secrets or External Secrets.
- `machine-deletion-remediation-operator` only applies on Machine API clusters.
