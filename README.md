# IdPlatformKit Orchestrator

[![e2e](https://github.com/idPlatformKit/Orchestrator/actions/workflows/e2e.yaml/badge.svg)](https://github.com/idPlatformKit/Orchestrator/actions/workflows/e2e.yaml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Crossplane](https://img.shields.io/badge/Crossplane-v2.4-5b3fd9)](https://crossplane.io)

**The self-service infrastructure layer of [IdPlatformKit](https://github.com/idPlatformKit)**, a reference Internal Developer Platform.

A development team declares *what* it needs in a few lines of YAML. Crossplane turns that into a secured, isolated environment:

```yaml
apiVersion: platform.idplatformkit.io/v1alpha1
kind: Tenant
metadata:
  name: demo-team
spec:
  ownerGroup: demo-team-engineers   # gets `edit` on the namespace
  vault:
    enabled: true                   # dedicated, isolated OpenBao namespace
    serviceAccountName: demo-app
```

→ a namespace with `ResourceQuota`, `LimitRange`, RBAC and a default-deny `NetworkPolicy`, plus its own secrets namespace, KV mount, policy and Kubernetes auth role in OpenBao, and a `SecretStore` so the team gets those secrets as Kubernetes `Secret`s through External Secrets Operator.

The whole thing runs **locally on kind in one command**, no cloud account needed.

## Quick start

Requires `kind`, `helm` and `kubectl`.

```sh
make local-up                # kind cluster + Crossplane + providers + shared Postgres & OpenBao + compositions
make try-tenant              # create a Tenant and show everything it produced
make try-postgres-database   # create a logical Postgres database and print its connection Secret
make local-down              # clean up
```

Or let Argo CD install the same thing from this repo, the GitOps way:

```sh
make local-up-gitops         # kind + Argo CD, which syncs the platform from this repo and the claims from idPlatformKit/instances
```

See [docs/gitops.md](docs/gitops.md).

## Composition library

| Composition | Scope | What a team gets | Docs |
|---|---|---|---|
| `Tenant` | Cluster | Namespace baseline (quota, limits, RBAC, default-deny network) + optional isolated OpenBao namespace | [tenant.md](docs/compositions/tenant.md) |
| `PostgresDatabase` | Namespaced | Logical database + role, connection details delivered as a Secret | [postgres-database.md](docs/compositions/postgres-database.md) |

## Design choices worth knowing

- **Crossplane v2**: namespaced XRs and native Kubernetes resources composed directly, no `provider-kubernetes`.
- **OpenBao instead of Vault**: real per-tenant Namespaces are free in OpenBao, Enterprise-only in Vault. Each tenant gets genuine isolation, not path prefixes on a shared mount.
- **Optional features without duplicated Compositions**: the Vault add-on is toggled with `function-cel-filter`.
- **One source of truth**: `providers/` and `compositions/` are kustomize bases shared by the local flow and the Argo CD flow.

Full rationale in [docs/architecture.md](docs/architecture.md).

## Status

- ✅ Local kind environment, end-to-end tested in CI
- ✅ `Tenant` with optional OpenBao namespace
- ✅ `PostgresDatabase`
- ✅ Argo CD bootstrap (app of apps), end-to-end tested in CI
- ✅ Claims synced by Argo CD from the [instances](https://github.com/idPlatformKit/instances) repository, validated in CI
- ✅ Backstage Software Template opening a pull request with a `Tenant` claim ([portal](https://github.com/idPlatformKit/portal)). Verified end to end, from the form to a `Ready` Tenant
- ✅ Each tenant's Kubernetes and Crossplane resources visible in the portal (Backstage Kubernetes plugin, read-only access)

Backing services (Postgres, OpenBao) run in single-replica dev mode with fixed local credentials. **This is a reference implementation, not production-ready.**

## Roadmap

1. **Secrets delivery**: External Secrets Operator pulling each tenant's OpenBao secrets into Kubernetes `Secret`s.
2. **Composition nesting**: `PostgresDatabase` provisioned from within a `Tenant`.
3. **Guardrails**: Kyverno policies and per-tenant observability.

Follow progress in the [issues](https://github.com/idPlatformKit/Orchestrator/issues).

## Part of IdPlatformKit

| Repo | Role |
|---|---|
| [portal](https://github.com/idPlatformKit/portal) | Developer portal (Backstage, GitHub auth, org/group sync) |
| **Orchestrator** | Platform orchestrator (Crossplane compositions) |
| [instances](https://github.com/idPlatformKit/instances) | Claims (`Tenant`, `PostgresDatabase`), synced by Argo CD |

Write-ups:
- TODO_TITRE_ARTICLE_1 : TODO_LIEN_1
- TODO_TITRE_ARTICLE_2 : TODO_LIEN_2

## License

[Apache 2.0](LICENSE)