# Environments

A tenant runs in one or more of the platform's environments, **staging** and **prod**. Each one is a namespace with its own rules: staging is where the team works, prod only runs what was promoted to it and is stricter. ([#63](https://github.com/idPlatformKit/Orchestrator/issues/63))

```yaml
apiVersion: platform.idplatformkit.io/v1alpha1
kind: Tenant
metadata:
  name: shop
spec:
  ownerGroup: team-a
  environments: [staging, prod]   # the default; [staging] or [prod] alone also work
```

This `Tenant` creates the namespaces `shop-staging` and `shop-prod`.

## What each environment changes

| | staging | prod |
|---|---|---|
| Namespace | `<tenant>-staging` | `<tenant>-prod` |
| Pod Security Standard (enforced by Pod Security Admission) | `baseline` | `restricted` |
| Warnings at apply time | against `restricted`: what wouldn't run in prod | against `restricted` |
| Owner team's rights in the namespace | `edit` | `view`: changes go through pull requests |
| Images | any | pinned by digest (`image@sha256:...`), Kyverno `prod-images-by-digest` |
| Replicas of Deployments and StatefulSets | any | at least 2, Kyverno `prod-min-replicas` |
| Resources required, owner label, quota, LimitRange, network policy | yes | yes |
| OpenBao secrets (when `spec.vault.enabled`) | mount `staging` in the tenant's OpenBao namespace | mount `prod` |

The rules come from two places:

- **The Tenant composition** labels each namespace with `platform.idplatformkit.io/environment` and the Pod Security labels, and binds the owner team to `edit` or `view` (`compositions/tenant/composition.yaml`).
- **Kyverno policies** select prod namespaces by that label (`platform/policies/prod-*.yaml`). The guardrails common to every environment are in [guardrails.md](guardrails.md).

An environment is a concept, not a place. On kind, both live in the same cluster as namespaces, so this is a simulation of separate environments: they share nodes, the Postgres and OpenBao servers, and the platform. With multi-cluster ([#36](https://github.com/idPlatformKit/Orchestrator/issues/36)), an environment will map to a cluster and Argo CD will place each tenant's namespaces by environment, with the same `Tenant` API.

## Staging is isolated from prod

- **Network**: each namespace only accepts traffic from its own pods. Staging can't reach prod.
- **Secrets**: each environment has its own KV mount, policy, Kubernetes auth role and `SecretStore`. The role of an environment only accepts the tenant's ServiceAccount from that environment's namespace. Tested by `make try-tenant`:
  - staging's `ExternalSecret` gets staging's value, and prod's gets prod's;
  - a token obtained with staging's ServiceAccount is refused on prod's mount (`403`);
  - staging's ServiceAccount logging in with prod's role is refused (`namespace not authorized`).
- **People**: the owner team reads and writes the secrets of both environments in OpenBao's UI or CLI (role `tenant-<name>`). Secrets aren't in Git, so someone has to write prod's: the team, not the platform.

## Claims in an environment

A `PostgresDatabase` (and later any app service) lives in the namespace of one environment. In the instances repository, folders are namespaces:

```
tenants/shop.yaml
databases/shop-staging/orders.yaml     # namespace: shop-staging
databases/shop-prod/orders.yaml        # namespace: shop-prod
```

The two are separate databases on the shared server: `shop-staging_orders` and `shop-prod_orders`. The portal's New Postgres database template asks for the environment.

## Promotion

Prod runs exactly what was tested in staging: the same image, by digest. The "new app" golden path ([#24](https://github.com/idPlatformKit/Orchestrator/issues/24)) builds each image once, deploys it to staging, and opens the pull request that promotes the same digest to prod, reviewed by the owner team. Until then, the platform side is in place: prod refuses images that aren't pinned by digest, and the team can't change prod with kubectl.

## What was actually observed

On kind, with the GitOps flow and the `demo-team` tenant of `make try-tenant` (both environments, OpenBao enabled):

- **Creation**: `Ready` in 13 to 18 seconds on a clean cluster, deletion (Tenant and both namespaces gone) in 6 to 7 seconds, including when deleted 3 seconds after `Ready`.
- `make try-tenant`: each environment got its own secret, and the cross-environment attempts were refused, as listed above.
- `make try-guardrails`: the same Deployment, image by tag and 1 replica, was accepted in staging, with the warning `would violate PodSecurity "restricted:latest"`, and refused in prod:

  ```
  Policy prod-min-replicas failed: In prod, Deployments run at least 2 replicas (spec.replicas: 1);
  Policy prod-images-by-digest failed: In prod, images are pinned by digest (image@sha256:...), the one promoted from staging (not pinned: web)
  ```

- A Deployment pinned by digest, with 2 replicas and a `restricted` pod, ran in `demo-team-prod`: both pods `Running`, labelled with the owner team.

**First attempt: the sequencer didn't hold anything back.** The composition is a go-templating template (patch-and-transform can't loop over environments). Its first version marked the namespaces ready with the `gotemplating.fn.crossplane.io/ready: "True"` annotation, as the function's docs suggest for resources without a `Ready` condition. That annotation marks the *desired* resource ready, before it even exists, so `function-sequencer` let everything that lives in the namespace go first:

```
cannot compose resources: cannot apply composed resource "networkpolicy-staging": namespaces "demo-staging" not found
```

The annotation is now set only once the resource is observed, which is what patch-and-transform's `readinessChecks: None` did.

**Tenants took a minute to become Ready, before this change too.** With the namespaces fixed, a Tenant still took 57 seconds. Every OpenBao object was ready within 3 seconds, but the `SecretStore`s were only created a minute later. `function-sequencer` v0.6.0 returns its response with a 1 minute TTL, and Crossplane reconciled the Tenant again only after it. The previous patch-and-transform composition, from `main`, measured the same way: 64 seconds. With `cacheTTL: 5s` on the sequencer step: 13 seconds. The price is a reconcile of each Tenant every 5 seconds.

## Migrating from single-namespace tenants

Before environments, a tenant was one namespace named after it. That API changed (`v1alpha1`): the namespace `<tenant>` is replaced by `<tenant>-<environment>`, and the claims that lived in it have to move. The tenant's data (databases, OpenBao secrets) doesn't move with it: it's a new start.

The procedure, as it was done on the test installation:

1. **Remove the databases, then the tenants**, from the instances repository, in two pull requests: wait for the databases to be gone before removing the tenants. Deleting a namespace while managed resources still live in it hangs ([#14](https://github.com/idPlatformKit/Orchestrator/issues/14)).
2. **Upgrade the Orchestrator.**
3. **Add the tenants and databases back** in the new layout: `environments` on each `Tenant`, and the databases in `databases/<tenant>-<environment>/` with `namespace: <tenant>-<environment>`. The portal's templates produce that layout.

On the test installation, the databases and tenants were removed in one step, by pointing the instances Application at an empty repository:

- **Argo CD refused to sync**: `Skipping sync attempt ... auto-sync will wipe out all resources`. Automated sync never prunes every resource of an Application. A sync triggered by hand did.
- **The tenant's deletion hung**, as described in #14. The database and the tenant were deleted together, and the database's `Role` and `Database` were still in the namespace when it started terminating. Each reconcile of a managed resource re-creates its `ProviderConfigUsage`, which a terminating namespace refuses:

  ```
  cannot apply ProviderConfigUsage: ... is forbidden: unable to create new content in namespace demo because it is being terminated
  ```

  It was unblocked by hand: drop the Postgres database and role, delete the OpenBao namespace, then remove the managed resources' finalizers. Hence the two pull requests in step 1.

With environments, a tenant's OpenBao managed resources live in the platform's `idpk-tenants` namespace instead of the tenant's, so deleting a tenant no longer hangs on them: tenants deleted 3 seconds after `Ready` went away in 6 to 7 seconds, three times. The databases' managed resources still live in an environment's namespace: delete them before the tenant.

## Limits

- **One cluster on kind**: staging and prod share nodes and backing services. Load in staging can affect prod.
- **The same quota and LimitRange in both environments.** Per-environment sizes will come with tenant tiers ([#30](https://github.com/idPlatformKit/Orchestrator/issues/30)).
- **Pod Security `restricted` is enforced on pods only**: Pod Security Admission only warns about a Deployment whose pods would be refused. The Deployment is accepted, and its pods then fail to be created. The warning is shown at `kubectl apply`, and in staging too, before it's too late.
- **No PodDisruptionBudget yet**: 2 replicas don't prevent a drain from evicting both at once. The `App` API ([#24](https://github.com/idPlatformKit/Orchestrator/issues/24)) is where it will be composed.
- **Removing an environment from a tenant deletes its namespace and everything in it**, like removing the tenant: remove its databases first (#14). Its OpenBao mount should stay in OpenBao until the tenant is deleted, since mounts are never deleted on their own (see [compositions/tenant.md](compositions/tenant.md)). Not tested yet.
- The environments are a fixed list, staging and prod. Another one (for example `preprod`) means changing the XRD's enum, the composition's rules and the policies.
