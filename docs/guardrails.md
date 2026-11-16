# Tenant guardrails

Every tenant namespace gets the same baseline rules, and prod namespaces stricter ones ([environments.md](environments.md)). They're enforced when a resource is created or updated: a workload that breaks one is refused with a message that says what to fix. Platform namespaces aren't affected.

| Rule | Enforced by | What happens |
|---|---|---|
| No pod below the **baseline** Pod Security Standard in staging, **restricted** in prod. Baseline: no privileged containers, host namespaces, `hostPath` volumes, added capabilities beyond the defaults... Restricted adds: non-root, `allowPrivilegeEscalation: false`, all capabilities dropped, a `RuntimeDefault` seccomp profile | Pod Security Admission, built into Kubernetes: the label `pod-security.kubernetes.io/enforce` on the namespace, set by the Tenant composition per environment | Pods refused. Deployments and other workloads are accepted with a warning (`pod-security.kubernetes.io/warn: restricted` in every environment), and their pods are refused |
| Every container of a workload declares **`requests.cpu`, `requests.memory` and `limits.memory`** | Kyverno `ValidatingPolicy` `tenant-require-resources` (`platform/policies/require-resources.yaml`) | Deployments, StatefulSets, DaemonSets, Jobs and CronJobs without them are refused. A bare Pod gets the LimitRange's defaults first, so it passes |
| Every pod carries the **team that owns the tenant**, `platform.idplatformkit.io/owner` | Kyverno `MutatingPolicy` `tenant-owner-label` (`platform/policies/owner-label.yaml`) | Set by the platform from the namespace, overwriting whatever the manifest says |
| **Prod**: every image is **pinned by digest** (`image@sha256:...`), the one promoted from staging | Kyverno `ValidatingPolicy` `prod-images-by-digest` (`platform/policies/prod-images-by-digest.yaml`), on namespaces labelled `platform.idplatformkit.io/environment: prod` | Pods and workloads refused, with the containers to fix |
| **Prod**: Deployments and StatefulSets run **at least 2 replicas** | Kyverno `ValidatingPolicy` `prod-min-replicas` (`platform/policies/prod-min-replicas.yaml`) | Refused. Scaling through the `scale` subresource (`kubectl scale`, an autoscaler) isn't checked |

## How it fits together

- **The Tenant composition labels its namespaces** (`compositions/tenant/composition.yaml`), one per environment: `platform.idplatformkit.io/tenant: <name>`, `platform.idplatformkit.io/environment: <staging|prod>`, `platform.idplatformkit.io/owner: <ownerGroup>`, and the Pod Security Admission labels. The policies select tenant namespaces on those labels, so they never touch `kube-system`, Argo CD, Crossplane or the other platform services, and a new tenant is covered as soon as it exists.
- **Pod security is Kubernetes' own.** Pod Security Admission implements the official Pod Security Standards exactly, with nothing to install or keep up to date. Rewriting them as Kyverno policies would only add something to maintain.
- **Kyverno does what Pod Security Admission can't**: requiring resources, setting labels, and prod's rules on images and replicas. Its policies are the CEL-based `ValidatingPolicy` and `MutatingPolicy` (`policies.kyverno.io/v1`): `ClusterPolicy` is deprecated in Kyverno 1.19.
- **Resources are required on workloads, not only on pods.** The rule is written for Pods, and Kyverno's autogen applies it to the pod template of Deployments, StatefulSets, DaemonSets, Jobs and CronJobs. A Deployment without resources is therefore refused at `kubectl apply` or at the Argo CD sync, rather than accepted and then failing to create pods. CPU limits stay optional: they throttle more than they protect.
- **Prod's warnings start in staging.** Pod Security Admission only enforces on pods: a Deployment whose pods break the standard is accepted, and its pods are then refused by the ReplicaSet controller. The `warn: restricted` label on every tenant namespace shows the problem at `kubectl apply` time, in staging already, before the workload reaches prod.
- **The owner label is set rather than required.** Asking every team to type their team name into every manifest adds friction and gets it wrong. The namespace already knows the owner, so the platform copies it onto every pod, including the pods of Deployments and Jobs, which are created through admission too. Per-tenant observability (#25) and `kubectl get pods -A -l platform.idplatformkit.io/owner=team-a` can rely on it.

Kyverno runs in dev mode, one replica per controller (`platform/kyverno/values.yaml`). Its webhooks fail closed: if Kyverno is down, workloads can't be created in tenant namespaces, while platform namespaces aren't affected.

## Installing

Both flows install the same thing:

- **local flow**: `make kyverno-install` and `make policies-apply`, part of `make local-up`;
- **GitOps flow**: the `kyverno` Application (sync wave -2, chart version pinned in `bootstrap/apps/values.yaml`) and the `policies` Application (wave -1), before any Tenant exists (`bootstrap/apps/templates/guardrails.yaml`).

## Trying it

```sh
make try-tenant          # the demo-team tenant
make try-guardrails      # or TENANT=<name> ./scripts/try-guardrails.sh
```

`make try-guardrails` only uses server-side dry runs: admission runs in full, and nothing is created. It checks that:

1. in staging, a privileged pod is refused;
2. a Deployment without resources is refused;
3. a Deployment that declares its resources, with an image by tag and 1 replica, is accepted, with the warning that its pods wouldn't run in prod;
4. a pod claiming another owner gets the tenant's owner;
5. in prod, the Deployment of 3 is refused, for its tag and its single replica;
6. a pod that isn't `restricted` is refused;
7. a Deployment pinned by digest, with 2 replicas and a `restricted` pod, is accepted without warnings;
8. outside tenant namespaces, nothing changes.

Both CI jobs run it. The tenant needs both environments.

## What was actually observed

On kind (Kubernetes 1.36), with the GitOps flow and Kyverno 1.19.2 (chart 3.9.2), against the tenant `demo` owned by `team-a`, before environments: the five checks of that time (1 to 4 and 8 above) passed. Without a dry run, a compliant Deployment created in `demo` ran a pod labelled `platform.idplatformkit.io/owner=team-a`.

With environments, against the tenant `demo-team` of `make try-tenant` (messages shortened):

```
== demo-team-staging
1. A privileged pod (Pod Security Admission, baseline)
refused, as expected: ... violates PodSecurity "baseline:latest": privileged (container "shell" must not set securityContext.privileged=true)
2. A Deployment without resources (tenant-require-resources)
refused, as expected: ... Policy tenant-require-resources failed: Every container needs resources.requests.cpu, resources.requests.memory and resources.limits.memory (missing in: web)
3. A Deployment that declares its resources, image by tag, 1 replica
accepted, with the warning that its pods wouldn't run in prod: would violate PodSecurity "restricted:latest"
4. A pod claiming another owner, without resources (tenant-owner-label, LimitRange)
accepted, owner label set to demo-team-engineers, memory limit 512Mi from the LimitRange
== demo-team-prod
5. The same Deployment as 3 (prod-images-by-digest, prod-min-replicas)
refused, as expected: ... Policy prod-min-replicas failed: In prod, Deployments run at least 2 replicas (spec.replicas: 1); Policy prod-images-by-digest failed: In prod, images are pinned by digest (image@sha256:...), the one promoted from staging (not pinned: web)
6. A pod that isn't restricted (Pod Security Admission, restricted)
refused, as expected: ... violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (...), unrestricted capabilities (...), runAsNonRoot != true (...), seccompProfile (...)
7. A Deployment by digest, 2 replicas, restricted
accepted, without warnings
== outside tenant namespaces
8. Nothing changes
accepted in default
```

Without a dry run, the Deployment of check 7 ran in `demo-team-prod`: 2 pods `Running` under `restricted`, labelled with the owner team.

An unset `spec.replicas` is already `1` when Kyverno sees it: the API server sets defaults before admission webhooks run.

**First attempt: the owner label on pod templates failed.** The `MutatingPolicy` first had autogen for Deployments and the other workload kinds, like the validating one. For a Deployment, Kyverno 1.19 evaluated the mutation without rewriting its types, and refused every Deployment in tenant namespaces:

```
Policy tenant-owner-label: failed to evaluate policy: type mismatch: unexpected type name "Object.metadata", expected "Object.spec.template.metadata"
```

The mutation now applies to Pods only, with autogen off. Pods created by Deployments and Jobs still get the label, because they go through admission as well.

**Argo CD saw Kyverno as OutOfSync right after syncing it.** Its `policies.kyverno.io` CRDs stayed `OutOfSync` after a successful server-side apply. A server-side dry-run diff of the rendered CRD against the live one showed no difference. With `argocd.argoproj.io/compare-options: ServerSideDiff=true` on the Application, Argo CD compares the same way, and Kyverno is `Synced`.

## Limits

- No exceptions mechanism yet: a team that needs one (for example a privileged debug pod) has none. Kyverno's `PolicyException` and a reviewed pull request would be the way.
- Violations are only visible at admission time. Kyverno's policy reports aren't shown in the portal yet.
- Images aren't checked beyond prod's digests: no signature verification and no allowed registries.
- Pod Security `restricted` only refuses pods in prod. A prod Deployment whose pods break it is accepted (with a warning), and its pods then fail to be created.
