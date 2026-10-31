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
app-gitops/charts/service/                Deployment, Service, PDB, HTTPRoute
          + apps/sim/values.yaml          what is the application's own
          + apps/sim/manifests/           anything that is not a service
```

Adding an application is therefore two changes: its values here, and its entry in
`platform-gitops/tenants/`.

## `charts/service` — the shape every service gets

An HTTP service behind the platform gateway. The application states its image,
port, route and resources; the chart supplies what an EKS upgrade depends on, the
things that are easy to forget and only show as failed requests during a node roll:

| Default | Why |
|---|---|
| 3 replicas, PDB `maxUnavailable: 1`, `unhealthyPodEvictionPolicy: AlwaysAllow` | a drain always leaves two serving; a stuck pod never holds its node |
| Spread across nodes (hard) and zones (soft), counting only the current ReplicaSet | one node's drain never takes every replica |
| Karpenter nodes only | the system node group runs the platform and rolls first; applications move last |
| Readiness every 2s, after 25s; `preStop` sleep 10s | a new pod waits for its node's ztunnel; a terminating one leaves the endpoints before it stops serving |
| Rollout `maxUnavailable: 0`, `minReadySeconds: 5` | updates never drop below the replica count |
| Non-root, read-only root filesystem, no capabilities | writable directories are declared (`writableDirs`) |

`values.schema.json` and the templates refuse what would break that, at render time —
before Argo CD applies anything: fewer than two replicas, an image without a
digest, a memory request different from its limit, a `preStop` the grace period
would cut short, a missing route.

A new service:

```yaml
# apps/orders/values.yaml
image: ghcr.io/example/orders:1.4.0@sha256:<digest>
port: 8080
route:
  path: /orders
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits: { memory: 128Mi }
```

and its tenant in `platform-gitops/tenants/`, a copy of `app-sim.yaml` with the name
changed. Check the render locally:

```bash
helm template orders charts/service -f apps/orders/values.yaml -n app-orders
```

## `apps/sim` — disruption test

A workload built to survive voluntary disruption, plus a load generator that
proves it did. It exists to show an EKS upgrade, a Karpenter drift or a
consolidation is transparent to an application that is set up for it.

It is `charts/service` with podinfo's image, port and `/sim` route
(`apps/sim/values.yaml`) — every row of the table above, nothing added. The 25s
readiness delay is the one that came from here: the first disruption test lost six
requests to pods Ready before their node's ztunnel. `loadgen`
(`apps/sim/manifests/`) sends requests through the platform gateway so a disruption
shows up as failed requests.

Watch it during an upgrade:

```bash
kubectl -n app-sim logs deploy/loadgen -f          # ok/fail every 10s
kubectl -n app-sim get pods -o wide -w             # pods moving between nodes
kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type
```

A transparent roll is one with `fail=0` throughout. `loadgen` itself runs on the
system node group, so it is replaced once while that group rolls and its counters
restart. `logs -f` ends with the old pod; run it again to follow the new one.

`loadgen` is the live view, from inside the cluster through the gateway's Service.
The measurement of record is `eks-upgrade`'s own probe in `eks-terraform`: a loop on
the bastion requesting `/sim/` through the internal ALB — the path a client takes —
for the whole run, reported per phase in the run summary. It does not restart when a
node group rolls. On the hml 1.35 → 1.36 rehearsal: 6,826 requests, none failed.
Renaming this route means changing that workflow's `probe-path` input too.

## Rules

Same as the platform repository: no `kind: Secret` (the repository is public), no
`type: LoadBalancer` or `Ingress` (a controller-created load balancer never enters
Terraform state), and every image pinned by digest.
