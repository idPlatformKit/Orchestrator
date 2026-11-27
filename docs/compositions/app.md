# `App`

An application of a tenant, in one of its environments: its processes (components) and the services they use. The `spec` is what the app's repository describes in its `app.yaml`, plus the images its CI built. The developer never writes a Kubernetes manifest or a claim. ([#24](https://github.com/idPlatformKit/Orchestrator/issues/24))

```yaml
apiVersion: platform.idplatformkit.io/v1alpha1
kind: App
metadata:
  name: hello
  namespace: demo-team-staging          # <tenant>-<environment>
spec:
  images:                               # written by the app's CI, by digest
    hello: ghcr.io/idplatformkit/hello@sha256:023ab063...
  services:
    db: { type: postgres }
  components:
    web:
      image: hello
      port: 8080
      env:
        DATABASE_URL: ${services.db.url}
      expose: { path: / }
```

This is a **first prototype**: one kind of component (a Deployment, exposed over HTTP or not) and one kind of service (`postgres`). The format already has `components` and `services` as maps, so the other shapes of #24 (workers, scheduled tasks, migrations, gRPC, more services) can be added without breaking it.

## What it composes

| From | Composed | Name | Notes |
|---|---|---|---|
| each service | `PostgresDatabase` | `<app>-<service>` | Its connection details in the Secret `<app>-<service>-conn`. The platform API, not its managed resources: the `PostgresDatabase` composition still decides how a database is provided. `deletionPolicy: Retain` unless the service's deletion is confirmed (see [Protecting the data](#protecting-the-data)) |
| each component | `Deployment` | `<app>-<component>` | Created once the services it uses are `Ready` (see below) |
| each component with a `port` | `Service` | `<app>-<component>` | Probes on `/healthz` (liveness) and `/readyz` (readiness) |
| each component with `expose` | `NetworkPolicy` | `<app>-<component>-from-gateway` | The tenant's namespaces only accept traffic from their own pods: this lets the Gateway's proxy in, on that port only |
| the exposed components | `HTTPRoute` | `<app>` | On the platform Gateway, `https://<app>-<namespace>.127.0.0.1.nip.io`, one rule per component's `path` |
| each component, in prod | `PodDisruptionBudget` | `<app>-<component>` | `maxUnavailable: 1` |

Every object is labelled `platform.idplatformkit.io/app` (and `/component`), and `app.kubernetes.io/name` and `/component`.

### Environments

The function reads the environment from the namespace's `platform.idplatformkit.io/environment` label, set by the `Tenant` composition ([environments.md](../environments.md)). It asks Crossplane for the `Namespace` as a required resource. An `App` in a namespace without that label is refused: `namespace "default" isn't a tenant's environment`.

| | staging | prod |
|---|---|---|
| Replicas of each component | 1 | 2 |
| `PodDisruptionBudget` | no | yes |
| Images | any | by digest, refused otherwise by Kyverno's `prod-images-by-digest` |

The containers run with the `restricted` Pod Security settings in **every** environment (non-root, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp), so that what runs in staging runs in prod. Each one requests `cpu: 50m` and `memory: 64Mi` and is limited to `256Mi` unless the component's `resources` say otherwise, as Kyverno's `tenant-require-resources` requires.

### Service outputs in env

A value can reference a service's outputs, `${services.<name>.<output>}`. For `postgres`:

| Output | Example | Read from |
|---|---|---|
| `host`, `port`, `database`, `username`, `password` | `postgres-server-postgresql.postgres-system.svc.cluster.local` | the connection Secret's `host`, `port`, `dbname`, `username`, `password` |
| `url` | `postgres://user:pass@host:5432/db` (Go, Node, Python) | built from the others |
| `jdbcUrl` | `jdbc:postgresql://host:5432/db` (Spring Boot, with `username` and `password` separately) | built from the others |

The function never reads a Secret: it writes references, and the kubelet resolves them when it starts the container.

- A value that is exactly one plain output becomes a `secretKeyRef`.
- A built output, or a value mixing text and outputs, reads each output into a helper variable, `IDPK_<SERVICE>_<KEY>` (before the others: Kubernetes only expands variables defined earlier), and refers to it with Kubernetes' `$(VAR)` expansion:

  ```yaml
  - name: DATABASE_URL
    value: postgres://$(IDPK_DB_USERNAME):$(IDPK_DB_PASSWORD)@$(IDPK_DB_HOST):$(IDPK_DB_PORT)/$(IDPK_DB_DBNAME)
  ```

  This is safe in a URL because provider-sql generates alphanumeric passwords, and user and database names are `<namespace>_<name>`.
- A `$(` written by the app is escaped (`$$(`), so Kubernetes doesn't expand it.
- A reference to an unknown service or output is an error on the `App`, listing the outputs that exist.

### Ordering and readiness

A component is created only once every service it uses is `Ready`, so that its pods don't start before their connection Secret exists. Once created, it stays, even if a service is briefly not ready. The `App` is `Ready` when everything it composed is:

- a `PostgresDatabase` when its `Ready` condition is `True`;
- a `Deployment` when all its replicas are updated and available, for its current generation;
- an `HTTPRoute` when the Gateway accepted it;
- the other objects once they exist.

The `App`'s status reports the environment, the URL, and each service and component:

```yaml
status:
  environment: staging
  url: https://hello-demo-team-staging.127.0.0.1.nip.io
  services:
    db: { ready: true, secret: hello-db-conn }
  components:
    web: { ready: true, replicas: 1 }
```

## Protecting the data

An `App`'s `app.yaml` lives in the app's repository, and the `App` itself in the instances repository, synced by Argo CD with pruning. A line removed from `services`, a renamed service, or a removed file must not be enough to drop a database. Deleting data is a separate, explicit step, reviewed like any other change: the annotation `platform.idplatformkit.io/delete-services` on the `App`, listing the services whose data may be deleted (comma separated), or `"*"` for all of them.

```yaml
metadata:
  annotations:
    platform.idplatformkit.io/delete-services: old   # first pull request
# then remove `old` from spec.services, or the App: second pull request
```

Three layers, from the closest to the data:

| What happens | Without the annotation | Listed in the annotation |
|---|---|---|
| The `PostgresDatabase` is deleted, whatever deletes it | the database stays in Postgres (`deletionPolicy: Retain`, see [postgres-database.md](postgres-database.md#deleting-keeps-the-database-deletionpolicy)) | the function sets `deletionPolicy: Delete`: deleting it drops the database |
| A service is removed from `spec.services` (or its type changes) | the function keeps composing it, as is; it's listed in `status.retainedServices`, with a warning event | the function sets `Delete`, waits until it reached the database's object (`status.databaseManagementPolicies: ["*"]`), then stops composing it: the database is dropped |
| The `App` is deleted (`kubectl delete`, Argo CD pruning) | refused by the Kyverno policy `app-data-protection`, which names the services to confirm | allowed once every service, current or retained, is listed |

The refusal reads:

```
Policy app-data-protection failed: Deleting App hello would delete the data of its services (db, old):
confirm it first with the annotation platform.idplatformkit.io/delete-services: "db,old" (or "*")
```

**Deleting the tenant, or one of its environments, is allowed**: the policy lets an `App` go when its namespace is being deleted, since that's already an explicit decision, and the data survives it anyway (`Retain`). The databases are left on the server, unmanaged: re-creating the tenant and the `App` adopts them again, data included, or a person drops them.

**First attempt: the policy alone didn't protect anything.** The first version only had the function's retention and the policy on the `App`. Deleting the tenant while `hello` ran in staging (the policy then refused the `App`'s deletion even in a terminating namespace) left the namespace waiting with the policy's message, as intended, but the database was already dropped: the namespace controller deletes every kind of object in the namespace directly, the `PostgresDatabase` and provider-sql's `Database` too, not through the `App`. Protection has to live where the data is: hence `deletionPolicy: Retain` on `PostgresDatabase`.

`make try-app-protection` (after `make try-app`) checks each case in Postgres itself.

## The contract every app follows

The platform doesn't know languages or frameworks, only images. An image works with `App` if it:

- reads its configuration from environment variables and logs to stdout;
- answers `/healthz` and `/readyz` on its `port`, and stops gracefully on `SIGTERM`;
- runs as a **numeric** non-root user (`USER 65532`, not `USER nonroot`, see below), without privileges;
- in prod, is referenced by digest.

[`examples/app/hello`](../../examples/app/hello) is a minimal Go app that follows it, and answers `/` with the name of the database it reaches.

## The function

The `App` composition is one step, `function-app`, a composition function written in Go with [function-sdk-go](https://github.com/crossplane/function-sdk-go), in [`functions/app`](../../functions/app). Patch-and-transform and go-templating were set aside: resolving references, deciding the order and computing readiness per kind are code, and Go makes them testable.

- **Tests**: unit tests on the composition, the references and readiness (`make function-app-test`), and a render of the example without a cluster (`make render-app`, `ENV=prod`, `DB_READY=false`), with `crossplane render` against the function running locally.
- **Package**: the `function-app` workflow tests it, builds a Crossplane package for amd64 and arm64, and publishes `ghcr.io/idplatformkit/function-app:sha-<commit>` on every push, from any branch, so a branch can be installed on kind before it's merged. Pushes to `main` also publish `:main`.
- **Installed** by `providers/function-app.yaml`, pinned by commit like the portal's image. Changing the function means: push, wait for the workflow, then bump the tag there.

## Try it

```sh
make try-tenant        # the demo-team tenant, staging and prod
make try-app           # hello in staging, then the same image in prod
make try-app-protection   # removing a service, deleting the App, deleting the tenant
```

`make try-app` deploys `examples/app/app.yaml` in `demo-team-staging`, waits for `Ready`, and calls the app over HTTPS through the Gateway: it must answer with its own database. It then promotes it to `demo-team-prod` with the same image digest and checks prod's rules.

`kubectl get app` lists Argo CD's Applications (their short name is `app`): use the full name, `kubectl get apps.platform.idplatformkit.io -A`.

## What was actually observed

On kind, with the GitOps flow tracking the branch and the function installed from GHCR:

- `make try-app`, from a clean state: `Ready` in 2 to 4 seconds in staging, 13 seconds in prod (two pods), and each environment answered with its own database:

  ```
  GET https://hello-demo-team-staging.127.0.0.1.nip.io/ -> {"app":"hello","database":"demo-team-staging_hello-db"}
  GET https://hello-demo-team-prod.127.0.0.1.nip.io/ -> {"app":"hello","database":"demo-team-prod_hello-db"}
  ```

  The pod became ready 2 seconds after the `App` was created: the database was `Ready` within the same second.
- In prod: 2 available replicas, the `PodDisruptionBudget`, and the image staging ran, the same digest.
- Network isolation still holds: a pod in `demo-team-staging` reached `hello-web.demo-team-staging:8080` (`200`), but `hello-web.demo-team-prod:8080` timed out.
- Deleting the `App` with `--cascade=foreground` removed everything in 17 seconds, including the Postgres database and role.
- Errors are shown on the `App`'s `Synced` condition and as events:

  ```
  cannot compose resources: pipeline step "compose" returned a fatal result: component "web": env DSN:
  ${services.db.dsn}: a postgres service has no output "dsn" (outputs: database, host, jdbcUrl, password, port, url, username)
  ```

  ```
  cannot compose resources: cannot apply composed resource "deployment-web": admission webhook ... denied the request:
  Policy prod-images-by-digest failed: In prod, images are pinned by digest (image@sha256:...), the one promoted from staging (not pinned: web)
  ```

**First attempt: a Deployment never became ready.** The pods were `Running` and the `Deployment` `1/1`, but the `App` stayed at `Unready resources: deployment-web`, with `replicas: 0`. Observed resources reach a function as protobuf `Struct`s, whose numbers are `float64`: `unstructured.NestedInt64` found no `int64` and returned 0. The unit tests passed because they built the observed objects with `int64`. Rendering the real observed `Deployment` with `crossplane render` showed it. The function now reads both types, and the test uses `float64`, as Crossplane sends them.

**The image's user must be numeric.** The first `hello` image ended with distroless's `USER nonroot:nonroot`. With `runAsNonRoot: true`, the kubelet refused to start it: `container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root`. It's `USER 65532:65532` now.

**An image loaded into kind can't be referenced by digest.** `kind load docker-image` imports it under a generated name (`import-<date>@sha256:...`). `idpk-hello@sha256:<that digest>` was accepted by Kyverno, then failed to pull: `pull access denied, repository does not exist`. Prod needs a registry, so the `hello-image` workflow publishes `ghcr.io/idplatformkit/hello`, and `make try-app` uses it in both environments.

**A misleading RBAC message on errors.** When a `Deployment` can't be applied (refused by Kyverno, for example), Crossplane v2.4 adds a second message: `system:serviceaccount:crossplane-system:crossplane is not allowed to [get, list, watch, create, update, patch, delete] resource deployments/status.apps/v1`. Crossplane has the rights it needs on `deployments`. After a failed apply, it checks its own rights to explain the failure, and looks the resource up by kind in the API discovery: `deployments/status` has the kind `Deployment` too, and is the last match. The first message is the real one.

**Kyverno can't read `App`s on its own.** The first apply of `app-data-protection` configured its webhook, but the policy stayed not ready: `Policy is not ready for reporting, missing permissions: get platform.idplatformkit.io/v1alpha1, Resource=apps`. Kyverno ships with rights on built-in kinds only. The ClusterRole `kyverno:read-platform-apps` (`platform/policies/kyverno-read-apps.yaml`) aggregates read access into its admission and reports controllers. Granted after the policy, it wasn't enough: the policy's status is only evaluated again when the policy changes (touching it with an annotation made it ready). Applied together with kustomize, the ClusterRole comes first.

**Deleting then re-creating right away overlaps.** `kubectl delete` returns as soon as the `App` is gone, and its objects are deleted in the background. Applying it again within seconds raced with the deletion of the previous database: the old role couldn't be dropped while its database still existed, then the new one was created. It converged, but wait for the objects to be gone (or delete with `--cascade=foreground`) before re-creating.

## Limits

- **Retained databases aren't cleaned up**: after a tenant is removed on purpose, its databases stay on the server until a person drops them. Nothing lists them yet.
- Confirming a service in the annotation while its namespace is being deleted falls back into [#14](https://github.com/idPlatformKit/Orchestrator/issues/14): `Delete` makes the database's object connect to Postgres, which it can't do from a terminating namespace. Confirm and delete `App`s before their tenant.
- The annotation is on the `App` in the instances repository: whoever can merge there can confirm. There's no separate approval for deleting data yet ([#31](https://github.com/idPlatformKit/Orchestrator/issues/31) is about governance of that repository).
- One kind of component (Deployment) and one kind of service (`postgres`). Not yet: workers scaled on queues, scheduled tasks (`CronJob`), the `migrate` Job, gRPC routes, `calls`, OpenBao secrets in `env`, sidecars.
- Hostnames are `<app>-<namespace>`, one DNS label under the Gateway's wildcard certificate, at most 63 characters: the `App` is refused when it's longer.
- The Gateway accepts routes from every namespace ([gateway.md](../gateway.md#limits)): a tenant could publish a route for another app's hostname.
- No Backstage template, catalog entity or app repository skeleton yet: an `App` is written by hand.
- Replicas and resources aren't configurable per environment beyond the rules above.
