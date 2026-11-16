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

**Website: [idplatformkit.github.io](https://idplatformkit.github.io)**, with the architecture, the design decisions, a recorded demo and how to run it.

## Install

IdPlatformKit runs on **your own GitHub org**: its members sign in to the portal, its teams own the tenants, and your own instances repository holds the claims.

```sh
make setup    # checks your machine, then prepares your GitHub org: instances repository, OAuth App (guided)
make up       # the whole platform on kind, installed by Argo CD from Git (about 5 minutes)
```

Then open **https://portal.127.0.0.1.nip.io**, sign in with GitHub and create a tenant. `make status` shows every URL and what's left to do; `make down` deletes the cluster. Requires Docker, `kind`, `kubectl`, `helm`, `openssl` and the GitHub CLI; `make setup` checks them. Full guide: [docs/install.md](docs/install.md).

Platform UIs are served over HTTPS, no port-forwards: the portal, `https://argocd.127.0.0.1.nip.io` and `https://openbao.127.0.0.1.nip.io`. See [docs/gateway.md](docs/gateway.md) and [docs/gitops.md](docs/gitops.md).

### Just the compositions

To try the Crossplane compositions without Argo CD, the portal or a GitHub org:

```sh
make local-up                # kind cluster + Crossplane + providers + shared Postgres & OpenBao + compositions
make try-tenant              # create a Tenant and show everything it produced
make try-postgres-database   # create a logical Postgres database and print its connection Secret
make local-down              # clean up
```

## Composition library

| Composition | Scope | What a team gets | Docs |
|---|---|---|---|
| `Tenant` | Cluster | Namespace baseline (quota, limits, RBAC, default-deny network) + optional isolated OpenBao namespace | [tenant.md](docs/compositions/tenant.md) |
| `PostgresDatabase` | Namespaced | Logical database + role, connection details delivered as a Secret | [postgres-database.md](docs/compositions/postgres-database.md) |

## Design choices worth knowing

- **Crossplane v2**: namespaced XRs and native Kubernetes resources composed directly, no `provider-kubernetes`.
- **OpenBao instead of Vault**: real per-tenant Namespaces are free in OpenBao, Enterprise-only in Vault. Each tenant gets genuine isolation, not path prefixes on a shared mount.
- **Optional features without duplicated Compositions**: the Vault add-on is toggled with `function-cel-filter`.
- **HTTPS on kind with Gateway API**: Envoy Gateway, cert-manager and a local CA generated once on the host, on `*.127.0.0.1.nip.io` hostnames that need no DNS setup.
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
- ✅ Tenant secrets delivered as Kubernetes `Secret`s by External Secrets Operator, from the tenant's own OpenBao namespace (cross-tenant access refused by OpenBao, tested)
- ✅ Postgres databases added to a tenant from the portal (New Postgres database template), named `<namespace>_<name>` on the shared server so tenants can't collide ([#21](https://github.com/idPlatformKit/Orchestrator/issues/21))
- ✅ Install on your own GitHub org in two commands (`make setup`, `make up`), with the portal running in the cluster. Verified end to end on a second org ([#45](https://github.com/idPlatformKit/Orchestrator/issues/45))
- ✅ Single sign-on with Dex: GitHub teams of the installation's org as groups for Argo CD, kubectl and OpenBao (`platform-admins`, and each tenant's team on its own namespace and secrets) ([#28](https://github.com/idPlatformKit/Orchestrator/issues/28), [docs/sso.md](docs/sso.md))
- ✅ Dedicated identities for agents (read-only, expiring), CI (GitHub Actions OIDC, no stored kubeconfig) and break-glass (one hour, audited); no long-lived tokens, no shared Argo CD admin ([#29](https://github.com/idPlatformKit/Orchestrator/issues/29), [docs/access.md](docs/access.md))
- ✅ HTTPS entry point: Gateway API (Envoy Gateway), cert-manager with a local CA, `https://<name>.127.0.0.1.nip.io` for OpenBao and Argo CD, end-to-end tested in CI ([#27](https://github.com/idPlatformKit/Orchestrator/issues/27))

Backing services (Postgres, OpenBao) run in single-replica dev mode with fixed local credentials. **This is a reference implementation, not production-ready.**

## Roadmap

1. **Guardrails**: Kyverno baseline policies for tenant namespaces ([#8](https://github.com/idPlatformKit/Orchestrator/issues/8)).
2. **"New app" golden path**: from a form to a running app in a tenant, wired to its database and secrets ([#24](https://github.com/idPlatformKit/Orchestrator/issues/24)).
3. **Per-tenant observability**: a Grafana dashboard for each tenant ([#25](https://github.com/idPlatformKit/Orchestrator/issues/25)).

Beyond that, the longer-term roadmap runs from Milestone 4 to 13: HTTPS and certificates on kind (done), SSO with Dex, day-2 lifecycle and governance, the composition library as a product, developer experience, agentic development, tenancy tiers and multi-cluster, prod-like services, a cloud target, and AI platform services. Each milestone is a [`roadmap` issue](https://github.com/idPlatformKit/Orchestrator/issues?q=is%3Aissue%20label%3Aroadmap%20is%3Aopen), prefixed `[M4]` to `[M13]`.

Follow progress in the [issues](https://github.com/idPlatformKit/Orchestrator/issues).

## Part of IdPlatformKit

| Repo | Role |
|---|---|
| [portal](https://github.com/idPlatformKit/portal) | Developer portal (Backstage, GitHub auth, org/group sync), runs in the cluster |
| **Orchestrator** | Platform orchestrator (Crossplane compositions) |
| [instances-template](https://github.com/idPlatformKit/instances-template) | Starting point of each installation's instances repository |
| [instances](https://github.com/idPlatformKit/instances) | The demo installation's claims (`Tenant`, `PostgresDatabase`), synced by Argo CD |

Write-ups, on the Backstage foundations of the portal:
- [Backstage.io Series, Part 1: Getting Started & Setting Up PostgreSQL](https://antoyavin.github.io/writing/backstage-series-part-1-getting-started/)
- [Backstage.io Series, Part 2: GitHub Authentication & User Ingestion](https://antoyavin.github.io/writing/backstage-series-part-2-github-auth/)

More on [Anas Touil's blog](https://antoyavin.github.io/writing/).

## License

[Apache 2.0](LICENSE)