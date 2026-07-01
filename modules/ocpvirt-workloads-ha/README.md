# ocpvirt-workloads-ha

Kustomize module for OpenShift Virtualization workload high-availability
operators: node maintenance, self-node remediation, node health check, and
kube descheduler.

## Layout

```
modules/ocpvirt-workloads-ha/
├── components/                     # per-operator install/config bases
├── overlays/                       # install, config, config-descheduler, all
└── argocd/
    ├── appproject.yaml             # dedicated Argo CD project (not default)
    ├── applicationset.yaml         # generates all Applications
    ├── kustomization.yaml          # bootstrap: AppProject + ApplicationSet
    └── rbac/                       # Argo CD controller RBAC
```

## Kustomize builds

Run from the repository root:

```sh
kubectl kustomize modules/ocpvirt-workloads-ha/overlays/install
kubectl kustomize modules/ocpvirt-workloads-ha/overlays/config
kubectl kustomize modules/ocpvirt-workloads-ha/overlays/config-descheduler
```

## Bootstrap (one time per cluster)

```sh
oc apply -k modules/ocpvirt-workloads-ha/argocd
oc apply -f modules/ocpvirt-workloads-ha/argocd/applicationset.yaml
```

After bootstrap, manifest and config changes are delivered via `git push`.
InstallPlan approval remains a cluster operation (`./scripts/approve-installplan.sh`).

Full guide: [repository README](../../README.md)
