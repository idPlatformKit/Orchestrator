# Architecture

## Purpose and scope

`Orchestrator` bootstraps the base platform tooling for IdPlatformKit and hosts a library of reusable Crossplane Compositions. It's deliberately split from the repository that will instantiate those compositions for real workloads:

```mermaid
flowchart LR
    subgraph Orchestrator["Orchestrator (this repo)"]
        A[Crossplane + Providers + Functions] --> B[Composition library]
    end
    B -- "ArgoCD syncs" --> C[Target repo]
    C -- "creates claims: Tenant, PostgresDatabase, ..." --> D[Running infra]
```

- **This repo**: installs Crossplane, the providers/functions Compositions need, and the reusable `XRD`/`Composition` pairs themselves.
- **The target repo** (separate, not this one): creates the actual claims (`Tenant`, `PostgresDatabase`, ...) that instantiate infrastructure. Argo CD installs this repo's platform layer (Crossplane, providers, shared services, compositions) and syncs the claims from that target repo, [idPlatformKit/instances](https://github.com/idPlatformKit/instances).

## Two ways to install

| Path | Entry point | Use case |
|---|---|---|
| Local, no GitOps | `make local-up` (root `Makefile`) | Try a composition on a disposable [kind](https://kind.sigs.k8s.io/) cluster, no cloud credentials, no ArgoCD |
| GitOps | `make local-up-gitops`: Argo CD app of apps in [`bootstrap/`](../bootstrap) | Same end state, installed and kept in sync by Argo CD from Git. See [gitops.md](gitops.md) |

Both paths apply the exact same `compositions/` and `providers/` kustomize bases — there is one source of truth for what gets installed, regardless of how it gets there. See the root [README](../README.md) for the exact commands.

## Layers

```mermaid
flowchart TB
    subgraph L1["Foundational (providers/, platform/)"]
        CP[Crossplane v2.4.0]
        PSQL[provider-sql]
        PVAULT[provider-vault]
        FN[Functions: patch-and-transform, auto-ready, cel-filter, sequencer]
        RBAC[ClusterRole: native resource composition]
        PG[(shared Postgres server)]
        OB[(shared OpenBao server)]
        ESO[External Secrets Operator]
    end
    subgraph L2["Composition library (compositions/)"]
        XRD1[PostgresDatabase XRD + Composition]
        XRD2[Tenant XRD + Composition]
    end
    subgraph L3["Claims (examples/, or the target repo)"]
        C1[PostgresDatabase claim]
        C2[Tenant claim]
    end
    CP --> XRD1
    CP --> XRD2
    PSQL --> XRD1
    PG --> XRD1
    PVAULT --> XRD2
    OB --> XRD2
    ESO --> XRD2
    FN --> XRD1
    FN --> XRD2
    RBAC --> XRD2
    C1 --> XRD1
    C2 --> XRD2
```

### Why Crossplane v2

The repo runs Crossplane **v2.4.0**, not v1. Two v2 features are load-bearing, not incidental:

1. **Namespaced XRs.** A v1-style separate "claim" kind isn't needed — `PostgresDatabase` XRs are created directly, namespaced, by the caller. `Tenant` is the one exception: it's `scope: Cluster` because a Tenant claim *mints a new namespace*, so it can't itself live inside one.
2. **Composing native Kubernetes resources directly.** The `Tenant` composition creates a `Namespace`, `ResourceQuota`, `LimitRange`, `RoleBinding` and `NetworkPolicy` with no `provider-kubernetes` involved — Crossplane v2 composes any Kubernetes resource, not just managed resources. This requires explicitly granting Crossplane's controller RBAC for those kinds (see below); it doesn't get that for free.

### Providers and Functions (`providers/`)

Applied once, before any composition or claim — these are prerequisites, not part of the reusable library itself.

| Name | Kind | Purpose |
|---|---|---|
| `provider-sql` | Provider | Manages logical databases/roles on the shared Postgres server (`PostgresDatabase`) |
| `provider-vault` | Provider | Manages Vault/OpenBao namespaces, mounts, policies and Kubernetes auth (`Tenant`'s optional add-on) |
| `function-patch-and-transform` | Function | The composition engine for both XRDs — patches an XR's spec onto a set of composed resource templates |
| `function-auto-ready` | Function | Marks composed resources `Ready` once their own health signals say so (Crossplane managed resources) |
| `function-cel-filter` | Function | Conditionally drops composed resources from the desired set based on a CEL expression over the XR's spec — this is how `Tenant`'s optional Vault add-on is toggled without a second Composition |
| `function-sequencer` | Function | Holds composed resources back until the ones they depend on are `Ready`. `Tenant` uses it to create its Namespace before what lives in it, and its Vault namespace before what lives in that |
| `crossplane-tenant-native-resources` | ClusterRole | Aggregates (`rbac.crossplane.io/aggregate-to-crossplane: "true"`) into Crossplane's own ClusterRole, granting it rights over `namespaces`, `resourcequotas`, `limitranges`, `rolebindings` and `networkpolicies` — plus the RBAC `bind` verb specifically on the `edit` ClusterRole, which Kubernetes' privilege-escalation check requires before Crossplane can create a `RoleBinding` to it |
| `postgres-providerconfig.yaml`, `openbao-providerconfig.yaml` | ClusterProviderConfig | Point `provider-sql`/`provider-vault` at the shared local Postgres/OpenBao servers |

Plain native-resource composed objects (`Namespace`, `ResourceQuota`, ...) don't carry a `Ready` status condition the way managed resources do — the `Tenant` composition marks those `readinessChecks: [{type: None}]` (ready as soon as created) rather than relying on `function-auto-ready` to infer it, since that inference isn't reliable across provider/function versions (see [compositions/tenant.md](compositions/tenant.md) for how this was actually discovered).

### Shared platform services (`platform/`)

Two "foundational infrastructure" servers, installed directly via Helm (not provisioned *by* Crossplane) — the same tier as Crossplane and Argo CD themselves, and explicitly **not production-grade**: single replica, dev/in-memory modes, fixed local credentials.

- `platform/postgres-server/` — Bitnami `postgresql` chart. One shared server; `PostgresDatabase` claims get a logical database + role on it (see [compositions/postgres-database.md](compositions/postgres-database.md)).
- `platform/openbao-server/` — [OpenBao](https://openbao.org/) (not HashiCorp Vault) in dev mode. Chosen specifically because it ships real Vault **Namespaces** — genuine per-tenant secrets isolation — free in its community edition, where Vault gates that behind Enterprise. See [compositions/tenant.md](compositions/tenant.md) for why that distinction mattered here.

## Composition library (`compositions/`)

| Composition | Scope | What it gives a caller |
|---|---|---|
| [`PostgresDatabase`](compositions/postgres-database.md) | Namespaced | A logical Postgres database + role, connection details in a Secret |
| [`Tenant`](compositions/tenant.md) | Cluster | A namespace baseline (quota, RBAC, network policy) plus an optional, toggleable, genuinely-isolated Vault secrets space |

Both follow the same shape: one shared backing service (Postgres / OpenBao) installed once at the platform level, and a Composition that provisions a caller-scoped slice of it (a database+role / a Vault namespace) rather than a dedicated instance per claim. That keeps local `kind` usage cheap and fast; it is a deliberate simplicity trade-off, not a scalability claim for a real multi-tenant production cluster.

## Non-goals / current limitations

- No production hardening: both shared backing servers run in single-replica, dev/in-memory modes with fixed local credentials — fine for `kind`, not for a real cluster.
- Argo CD installs the platform layer and syncs the claims from the instances repository. Claims are opened there by the portal's New Tenant template, or by hand. Argo CD itself is installed by Helm, not self-managed, and the dev bootstrap Secrets are created imperatively (see [gitops.md](gitops.md)).
- `Tenant`'s Vault add-on delivers secrets as Kubernetes `Secret`s through External Secrets Operator (one namespaced `SecretStore` per tenant, logging in with the tenant's own Kubernetes auth role), but it doesn't write any secret itself: populating OpenBao is the team's job.
- `PostgresDatabase` is not (yet) composable *from* a `Tenant` claim (nested XR composition), even though Crossplane supports it — each composition is proven independently first.
