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
`platform-gitops/tenants/`: one short file per application under `registry/`, from
which the platform renders its `Namespace` (with the mesh, gateway and secrets labels)
and its `Application`, which points back here.

```
platform-gitops/tenants/registry/sim.yaml  Namespace app-sim + Application
        │
        ▼
app-gitops/charts/service/                Deployment, Service, PDB, HTTPRoute
          + apps/sim/values.yaml          what is the application's own
          + apps/sim/manifests/           anything that is not a service
```

Adding an application is therefore two changes: its values here, and its file in
`platform-gitops/tenants/registry/`. Reading secrets adds nothing but `secrets: true`
there — no Terraform.

Its code lives in its own repository, which builds and releases through ci-templates'
`service-release` (see [Releases](#releases)). The reference is
[`hello-api`](https://github.com/gulinux86/hello-api): its code repository,
`apps/hello-api/values.yaml` here and `tenants/registry/hello-api.yaml` there.

## `charts/service` — the shape every service gets

An HTTP service behind the platform gateway. The application states its image,
port, route and resources; the chart supplies what an EKS upgrade depends on, the
things that are easy to forget and only show as failed requests during a node roll:

| Default | Why |
|---|---|
| 3 replicas, PDB `maxUnavailable: 1`, `unhealthyPodEvictionPolicy: AlwaysAllow` | a drain always leaves two serving; a stuck pod never holds its node |
| HPA on CPU, 3–6 replicas at 70% of the request; scale-down one pod a minute after five calm minutes | load is absorbed without a values change; the Deployment carries no `replicas`, so Argo CD never undoes a scale-up |
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

and its tenant, `platform-gitops/tenants/registry/orders.yaml`:

```yaml
name: orders
team: checkout
gateway: true
secrets: true     # only if it reads secrets; see below
```

CI renders it on the pull request (see [CI](#ci)); to check before
pushing:

```bash
helm template orders charts/service -f apps/orders/values.yaml -n app-orders
```

### Secrets

A value from AWS Secrets Manager reaches the container as an environment variable:

```yaml
# apps/orders/values.yaml
secrets:
  - env: DB_PASSWORD
    key: apps/orders/db
    property: password      # a field of a JSON secret; omit for a plain one
```

The chart renders one `ExternalSecret` through the `ClusterSecretStore` `aws`, and adds
the resulting Secret to the container with `envFrom`. Nothing about the value is in
Git; what is here is only where it lives.

An application reads only `apps/<application>/*`: that is all the cluster admits for
its namespace (an admission policy in platform-gitops), and the chart refuses any other
key before it reaches the cluster. The tenant needs `secrets: true` in platform-gitops;
no Terraform. The value itself is created in Secrets Manager — by Terraform
for infrastructure it provisions, or by hand:

```bash
aws secretsmanager create-secret --name apps/orders/db \
  --secret-string '{"password":"..."}'
```

A secret rotated in AWS reaches the Secret within `secretsRefreshInterval` (1h), and a
running container on its next restart.

### Releases

An application's own repository builds its image with ci-templates'
[`service-release`](https://github.com/gulinux86/ci-templates#service-release) workflow.
On a push to its `main` it builds, scans and pushes the image to ECR
(`apps/<app>`, created on the first push), then opens a pull request here that changes
one line — `image:` in `apps/<app>/values.yaml` — to the new digest. CI below validates
it like any other change, the image read back from ECR included; merging it is the
deploy. A newer release closes the older release pull requests of the same service.

So `image:` is the one line here a pipeline writes. Everything else in a values file is
reviewed by people.

## `apps/hello-api` — reference service

The smallest service that goes the whole way: code in
[`gulinux86/hello-api`](https://github.com/gulinux86/hello-api), released by
`service-release` into ECR, pinned here by its pipeline's pull requests, served at
`/hello`. Its values file is two lines — image and route; everything else is the
chart's defaults. A new service starts by copying it.

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

## CI

`.github/workflows/ci.yml` runs on every pull request into `main`, with no path
filters so each job can be a required check:

| Job | What fails it |
|---|---|
| `validate` | a values file the chart's schema or guards reject (`helm lint --strict`, `helm template`); an object the Kubernetes or CRD schemas reject (`kubeconform -strict`); a Secret, Ingress or LoadBalancer Service; an image not pinned by digest; two HTTPRoutes on the same path; an image its registry does not have; an image that runs as a named or root user with no `runAsUser` set |
| `diff` | nothing — it comments on the pull request with the rendered diff against `main`, so a review sees what Argo CD will apply |
| `lint` | actionlint on the workflows, shellcheck on the scripts |

Releases and namespaces follow the layout: `apps/<app>/values.yaml` is release `<app>`
in `app-<app>`; `apps/<app>/<svc>/values.yaml` is release `<app>-<svc>` in the same
namespace. The tenant in `platform-gitops` must use the same names; its CI checks that.

The same checks locally (helm and PyYAML; `--registry` also needs
[crane](https://github.com/google/go-containerregistry/tree/main/cmd/crane)):

```bash
./scripts/ci/render.sh /tmp/rendered
python3 scripts/ci/check.py /tmp/rendered --registry
```

Images in the account's ECR are read with the `ECR_READ_ROLE_ARN` secret (eks-terraform
bootstrap, output `ecr_read_role_arn`), assumed through OIDC: the `validate` job logs
crane in before `--registry` reads them. Locally, log crane in yourself:
`aws ecr get-login-password | crane auth login <registry> -u AWS --password-stdin`.
