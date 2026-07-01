# ocpvirt-workloads-ha

Kustomize module for OpenShift Virtualization workload high-availability
operators: node maintenance, self-node remediation, node health check, and
kube descheduler.

## Layout

```
modules/ocpvirt-workloads-ha/
├── kustomization.yaml              # module root → overlays/all
├── components/                     # per-operator install/config bases
├── overlays/
│   ├── install/                    # Phase 1: OLM subscriptions
│   ├── config/                     # Phase 2: namespaced config CRs
│   ├── config-descheduler/         # Phase 2: cluster-scoped KubeDescheduler
│   └── all/                        # full stack (local validation)
└── argocd/
    ├── applications/               # Argo CD Application CRs
    └── rbac/                       # Argo CD controller RBAC
```

## Kustomize builds

Run from the repository root:

```sh
kubectl kustomize modules/ocpvirt-workloads-ha/overlays/install
kubectl kustomize modules/ocpvirt-workloads-ha/overlays/config
kubectl kustomize modules/ocpvirt-workloads-ha/overlays/config-descheduler
kubectl kustomize modules/ocpvirt-workloads-ha
```

## Bootstrap

```sh
oc apply -f modules/ocpvirt-workloads-ha/argocd/rbac/ocpvirt-workloads-ha-argocd-rbac.yaml
oc apply -f modules/ocpvirt-workloads-ha/argocd/applications/root.yaml
```

Deployment, InstallPlan approval, recovery, troubleshooting, and OLM Classic
vs OLM v1 guidance:
[repository README](../../README.md)
