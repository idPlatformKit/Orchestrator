# GitOps bootstrap (Argo CD)

`make local-up-gitops` reaches the same end state as `make local-up` (Crossplane, providers, functions, the shared Postgres and OpenBao servers, the composition library), but only Argo CD and a few bootstrap Secrets are installed by hand. Argo CD installs everything else from this repository and keeps it in sync. It then provisions the claims declared in the separate [instances](https://github.com/idPlatformKit/instances) repository.

```sh
make local-up-gitops                                 # tracks main
make local-up-gitops GITOPS_REVISION=my-branch       # test a pushed branch
make local-up-gitops GITOPS_REPO_URL=https://github.com/<you>/Orchestrator.git GITOPS_REVISION=my-branch
make try-tenant && make try-postgres-database        # same checks as the local flow
```

The branch must be pushed: Argo CD runs inside the cluster and reads Git, not your working tree.

To reach the Argo CD UI:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080, user admin
```

## Layout

```
bootstrap/
├── argocd/values.yaml     # Argo CD chart values (installed by Helm, not by Argo CD)
├── root-app.yaml          # the one Application applied by hand
└── apps/                  # Helm chart rendering the child Applications
    ├── values.yaml        # Git source + pinned upstream chart versions
    └── templates/
```

The root Application `platform` renders `bootstrap/apps/` (the "app of apps" pattern). The child Applications reuse what the local flow already uses: `providers/` and `compositions/` are synced as-is, and the Postgres/OpenBao Helm charts read their values from `platform/*/values.yaml` through a multi-source Application. Nothing is duplicated per environment.

| Wave | Application | Source |
|---|---|---|
| -2 | `crossplane` | Crossplane Helm chart 2.4.0 |
| -1 | `postgres-server`, `openbao-server` | Upstream Helm charts + `platform/*/values.yaml` from this repo |
| 0 | `providers` | `providers/` kustomize base |
| 1 | `compositions` | `compositions/` kustomize base |
| 2 | `instances` | The [instances](https://github.com/idPlatformKit/instances) repository: `Tenant` and `PostgresDatabase` claims |

Chart versions are pinned in `bootstrap/apps/values.yaml` and in the Makefile (`CROSSPLANE_VERSION`, `POSTGRES_CHART_VERSION`, `OPENBAO_CHART_VERSION`). Keep both in sync.

## Bootstrap Secrets: deliberately not in Git

Three Secrets hold dev-default credentials and are created by `make bootstrap-secrets` before Argo CD syncs anything, exactly as the local flow does:

| Secret | Namespace | Read by |
|---|---|---|
| `postgres-server-auth` | `postgres-system` | Postgres chart (`auth.existingSecret`) |
| `postgres-admin-conn` | `postgres-system` | provider-sql `ClusterProviderConfig` |
| `openbao-creds` | `openbao-system` | provider-vault `ClusterProviderConfig` |

This imperative step is the honest stopgap until secrets are delivered by a proper mechanism (External Secrets Operator is on the roadmap). The values are the same fixed local credentials as in the Makefile and are only meant for kind.

## What was actually observed, gotchas included

All of this was run on a fresh kind cluster with Argo CD chart 10.11.1 (Argo CD v3.5.6). From an empty cluster, every Application was `Synced`/`Healthy` about 1.5 to 2 minutes after the root app was applied. `make try-tenant` and `make try-postgres-database` then passed unchanged.

**Sync waves don't order child apps out of the box.** Since Argo CD 1.8 the health of an `Application` resource is no longer assessed, so a parent app only waits for a child Application *object* to exist, not for it to be healthy. `bootstrap/argocd/values.yaml` restores the health check (`resource.customizations.health.argoproj.io_Application`). Without it, the waves are cosmetic.

**`ClusterProviderConfig` CRDs don't exist on the first sync.** They are installed by provider-sql and provider-vault, which the same Application has only just created. `SkipDryRunOnMissingResource=true` gets past the dry run, but the apply itself still fails:

```
resource mapping not found for name: "postgres-local" ...
no matches for kind "ClusterProviderConfig" in version "postgresql.sql.m.crossplane.io/v1alpha1"
ensure CRDs are installed first
```

The `providers` app goes `Degraded` for one retry cycle, then the retry (10s backoff) applies them once the Providers are healthy. This is expected and self-resolving. The local flow solves the same problem by applying the ProviderConfigs in a separate step (`providers-apply`).

**The root app is `Healthy` before it has done anything.** Right after creation it has no resources, so it reports `Healthy` while still `OutOfSync`. The first version of `make gitops-wait` waited on health only and returned immediately with the cluster half-installed. It now waits for `Synced` first, then `Healthy`.

**...and it was still `Healthy` one wave too early.** With that fixed, a second run printed `compositions OutOfSync Missing` next to a `Synced`/`Healthy` root. A child Application that hasn't synced yet reports `Missing`, and Argo CD doesn't count `Missing` against the parent's aggregated health. The first version of the health check passed the child's status through as-is. It now maps `Missing` to `Progressing`. A run polled every 5 seconds afterwards showed the waves in order (crossplane → shared services → providers → compositions), with the root only `Synced`/`Healthy` once `compositions` was. As a final guard, `make gitops-wait` also waits for every Application to be `Healthy`.

**Self-heal works on Crossplane objects.** Deleting the `tenant-incluster` Composition by hand: Argo CD had recreated it when checked 30 seconds later and the `compositions` app stayed `Synced`. No `ignoreDifferences` was needed for the Crossplane `Provider`, `Function`, XRD or Composition objects: none of them showed up as drifted.

## Claims from the instances repository

The `instances` Application syncs [idPlatformKit/instances](https://github.com/idPlatformKit/instances) (`main`) with `prune` and `selfHeal`. That repository validates every claim against this repo's XRDs in CI (`crossplane resource validate`), so a broken claim is caught in the pull request, before Argo CD sees it. Its location is set in `bootstrap/apps/values.yaml` (`instances.repoURL`, `instances.targetRevision`).

What was observed on a fresh kind cluster with the `checkout` example claims (a `Tenant` and a `PostgresDatabase` in the `checkout` namespace):

**Argo CD doesn't know when a claim is ready.** It ships health checks for Crossplane's own API groups (`*.crossplane.io`, `*.upbound.io`), not for ours, so a `Tenant` would show `Healthy` as soon as the object existed. `bootstrap/argocd/values.yaml` adds a health check for `*.idplatformkit.io/*` that maps the XR's `Synced`/`Ready` conditions. With it, the `instances` app stayed `Progressing` for about 90 seconds, until Crossplane reported the `Tenant` `Ready` (the OpenBao resources take the longest). Only then did the root app go `Healthy`.

**First attempt: a wildcard in the split key format.** `resource.customizations.health.platform.idplatformkit.io_*` was rejected by the API server when installing Argo CD: a ConfigMap key must match `[-._a-zA-Z0-9]+`, so `*` is not allowed. Wildcards only work in the older single-key `resource.customizations` block, which is also the format Crossplane's docs use for `*.upbound.io/*`.

**The `PostgresDatabase` lands before its namespace exists.** The `checkout` namespace is created by Crossplane from the `Tenant`, not by Argo CD. The dry run passed, but the first apply failed with `namespaces "checkout" not found`. The retry applied it about 20 seconds later. This is expected and self-resolving. Nesting `PostgresDatabase` inside `Tenant` (on the roadmap) removes the ordering problem altogether.

**Self-heal applies to claims too.** Patching the `Tenant`'s `ownerGroup` by hand: Argo CD had reverted it 25 seconds later, and the namespace's `RoleBinding` still pointed at `checkout-engineers`.

**Not tested yet: prune.** Removing a claim from the instances repository should delete the resource and, for a `Tenant`, its whole namespace. That's the intended GitOps behaviour, but it hasn't been exercised end to end here yet.

## Scope and limits

- Argo CD itself is installed by Helm and doesn't manage itself yet.
- Claims are added by hand-written pull requests to the instances repository for now. A Backstage Software Template opening those pull requests is the next step (see the [roadmap](../README.md#roadmap)).
- Same caveat as the local flow: dev-mode, single-replica backing services with fixed credentials. A reference setup, not a production one.
