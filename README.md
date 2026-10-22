# app-gitops

Applications, delivered by Argo CD. Everything that extends the cluster lives in
[`platform-gitops`](https://github.com/gulinux86/platform-gitops); the cluster itself
in [`eks-terraform`](https://github.com/gulinux86/eks-terraform).

## What this repository may do

Argo CD syncs it under the `apps` `AppProject`, which Terraform owns:

| | Allowed |
|---|---|
| Destination | namespaces matching `app-*` |
| Resources | namespaced only — no Namespace, CRD or ClusterRole(Binding) |

So an application here cannot create its own namespace, join the mesh, or attach to
the gateway on its own. Those are the platform's decisions, made in
`platform-gitops/tenants/`: one file per application holding its `Namespace` (with the
mesh and gateway labels) and its `Application`, which points back here.

```
platform-gitops/tenants/app-sim.yaml      Namespace app-sim + Application
        │
        ▼
app-gitops/apps/sim/                      Deployment, Service, PDB, HTTPRoute, …
```

Adding an application is therefore two changes: its manifests here, and its entry
in `platform-gitops/tenants/`.

## `apps/sim` — disruption test

A workload built to survive voluntary disruption, plus a load generator that
proves it did. It exists to show an EKS upgrade, a Karpenter drift or a
consolidation is transparent to an application that is set up for it.

| Piece | Why |
|---|---|
| 3 replicas, `maxUnavailable: 1` PDB | a drain always leaves two serving |
| Spread across nodes (hard) and zones (soft) | one node's drain never takes every replica |
| Karpenter nodes only | so Karpenter provisions, drifts and consolidates them |
| Readiness every 2s, `preStop` sleep 10s | a terminating pod leaves the endpoints before it stops serving |
| `maxUnavailable: 0` rollout, `minReadySeconds: 5` | updates never drop below three ready |
| memory `requests == limits` | Karpenter packs by requests |
| `loadgen` through the platform gateway | a disruption shows up as failed requests |

Watch it during an upgrade:

```bash
kubectl -n app-sim logs deploy/loadgen -f          # ok/fail every 10s
kubectl -n app-sim get pods -o wide -w             # pods moving between nodes
kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type
```

A transparent roll is one with `fail=0` throughout. `loadgen` itself runs on the
system node group, so it is replaced once while that group rolls and its counters
restart. `logs -f` ends with the old pod; run it again to follow the new one.

## Rules

Same as the platform repository: no `kind: Secret` (the repository is public), no
`type: LoadBalancer` or `Ingress` (a controller-created load balancer never enters
Terraform state), and every image pinned by digest.
