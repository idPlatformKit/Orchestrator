# Orchestrator

Orchestrator is a repository for installing the base Crossplane compositions for IdPlatformKit. This repository sets up foundational infrastructure components and will also include additional reusable compositions in the future.

After the base compositions are installed, the instantiation and management of specific compositions will be handled in a separate repository.

## Purpose

- Provide a quick setup for base Crossplane compositions.
- Include a library of reusable Crossplane compositions for future use.
- Install and configure ArgoCD, which is used here only to install ArgoCD itself and to synchronize with the target repository containing the actual composition instances.

## Key Points

- **This repository does not manage application-specific compositions.**
- **ArgoCD in this context is only used for its installation and for syncing with the target repo.**
- **Future updates will add more reusable Crossplane compositions.**

## Getting Started

1. Clone this repository.
2. Install Crossplane and ArgoCD using the provided manifests.
3. Configure ArgoCD to sync with your target repository for composition instantiation.

## Local Development (no GitOps)

To try compositions from the [compositions/](compositions/) library without setting up ArgoCD, spin up a local [kind](https://kind.sigs.k8s.io/) cluster:

```sh
make local-up    # creates the kind cluster, installs Crossplane, applies compositions/
make local-down  # tears the cluster down
```

`compositions/` is a kustomize base used by both this local flow (`make compositions-apply`) and the ArgoCD-driven flow, so there is a single source of truth for what gets installed either way. Requires `kind`, `helm`, and `kubectl` on your PATH.

### Try the first composition: self-service Postgres database

`compositions/postgres-database/` is a `PostgresDatabase` XRD + Composition that provisions a logical database (via [provider-sql](https://github.com/crossplane-contrib/provider-sql)) against a shared, in-cluster Postgres server — no cloud provider needed.

```sh
make local-up                  # cluster + Crossplane + provider-sql + shared Postgres + compositions
make try-postgres-database     # applies examples/postgres-database.yaml and prints the connection secret
```

### Try the second composition: self-service `Tenant`

`compositions/tenant/` is a `Tenant` XRD + Composition that gives a team a namespace baseline (`ResourceQuota`, `LimitRange`, an `edit` `RoleBinding` for `spec.ownerGroup`, a default-deny `NetworkPolicy`) and, optionally, a real per-tenant Vault namespace (`spec.vault.enabled`, via [provider-vault](https://github.com/upbound/provider-vault) against a local [OpenBao](https://openbao.org/) server) — all under one claim. The optional piece is gated with `function-cel-filter`, not duplicated Compositions.

OpenBao rather than Vault: Vault Community Edition gates real Namespaces (genuine per-tenant secrets isolation) behind Enterprise, while OpenBao — the Linux Foundation's open-source Vault fork — ships them free. Each tenant gets its own `VaultNamespace`, with its own `secret/` kv-v2 mount and policy inside it, not a shared mount with path prefixes.

```sh
make local-up      # also brings up provider-vault + the shared local OpenBao server
make try-tenant     # applies examples/tenant.yaml (vault.enabled: true) and shows what got created
```

Toggle `spec.vault.enabled` in a `Tenant` claim on or off (and re-apply) to see the tenant's `VaultNamespace`/`Mount`/`Policy` get created or torn down while the namespace baseline stays untouched — that's the mechanism future add-ons (e.g. nesting `PostgresDatabase` into a `Tenant`) will reuse.

#### Accessing a tenant's Vault namespace

`spec.vault.serviceAccountName` (required whenever `spec.vault` is set) names the **one** Kubernetes ServiceAccount, in the tenant's own namespace, allowed to authenticate as that tenant. The composition wires the trust relationship only — it doesn't create that ServiceAccount; create it yourself alongside your workload:

```sh
kubectl create serviceaccount <name> -n <tenant>
```

A pod running as that ServiceAccount logs in with its own projected token and gets back a token scoped to the tenant's policy:

```sh
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -s --request POST \
  --header "X-Vault-Namespace: <tenant>" \
  --data "{\"role\": \"tenant-access\", \"jwt\": \"$JWT\"}" \
  http://openbao.openbao-system.svc.cluster.local:8200/v1/auth/kubernetes/login
```

Any other ServiceAccount gets `"service account name not authorized"`. This Kubernetes-auth-to-policy path is also the prerequisite for a later goal: pulling these secrets into Kubernetes `Secret`s per tenant via [External Secrets Operator](https://external-secrets.io/) — ESO's Vault provider would authenticate the same way, against the same per-tenant role.

## Next Steps

- Use your target repository to manage and instantiate specific Crossplane compositions.
- Check back for new reusable compositions as they are added to this repository.
