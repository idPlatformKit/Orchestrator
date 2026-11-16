# Tenant guardrails

Every tenant namespace gets the same baseline rules, enforced when a resource is created or updated: a workload that breaks one is refused with a message that says what to fix. Platform namespaces aren't affected.

| Rule | Enforced by | What happens |
|---|---|---|
| No pod below the **baseline** Pod Security Standard: no privileged containers, host namespaces, `hostPath` volumes, added capabilities beyond the defaults... | Pod Security Admission, built into Kubernetes: the label `pod-security.kubernetes.io/enforce: baseline` on the namespace | Refused |
| Every container of a workload declares **`requests.cpu`, `requests.memory` and `limits.memory`** | Kyverno `ValidatingPolicy` `tenant-require-resources` (`platform/policies/require-resources.yaml`) | Deployments, StatefulSets, DaemonSets, Jobs and CronJobs without them are refused. A bare Pod gets the LimitRange's defaults first, so it passes |
| Every pod carries the **team that owns the tenant**, `platform.idplatformkit.io/owner` | Kyverno `MutatingPolicy` `tenant-owner-label` (`platform/policies/owner-label.yaml`) | Set by the platform from the namespace, overwriting whatever the manifest says |

## How it fits together

- **The Tenant composition labels its namespace** (`compositions/tenant/composition.yaml`): `platform.idplatformkit.io/tenant: <name>`, `platform.idplatformkit.io/owner: <ownerGroup>`, and the Pod Security Admission label. The policies select tenant namespaces on those labels, so they never touch `kube-system`, Argo CD, Crossplane or the other platform services, and a new tenant is covered as soon as it exists.
- **Pod security is Kubernetes' own.** Pod Security Admission implements the official Pod Security Standards exactly, with nothing to install or keep up to date. Rewriting them as Kyverno policies would only add something to maintain.
- **Kyverno does what Pod Security Admission can't**: requiring resources and setting labels. Its policies are the CEL-based `ValidatingPolicy` and `MutatingPolicy` (`policies.kyverno.io/v1`): `ClusterPolicy` is deprecated in Kyverno 1.19.
- **Resources are required on workloads, not only on pods.** The rule is written for Pods, and Kyverno's autogen applies it to the pod template of Deployments, StatefulSets, DaemonSets, Jobs and CronJobs. A Deployment without resources is therefore refused at `kubectl apply` or at the Argo CD sync, rather than accepted and then failing to create pods. CPU limits stay optional: they throttle more than they protect.
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

1. a privileged pod is refused;
2. a Deployment without resources is refused;
3. a Deployment that declares its resources is accepted;
4. a pod claiming another owner gets the tenant's owner;
5. outside tenant namespaces, nothing changes.

Both CI jobs run it.

## What was actually observed

On kind (Kubernetes 1.36), with the GitOps flow and Kyverno 1.19.2 (chart 3.9.2), against the tenant `demo` owned by `team-a`:

```
1. A privileged pod (Pod Security Admission, baseline)
refused, as expected: ... pods "guardrails-privileged" is forbidden: violates PodSecurity "baseline:latest": privileged (container "shell" must not set securityContext.privileged=true)
2. A Deployment without resources (tenant-require-resources)
refused, as expected: ... Policy tenant-require-resources failed: Every container needs resources.requests.cpu, resources.requests.memory and resources.limits.memory (missing in: web)
3. A Deployment that declares its resources
accepted
4. A pod claiming another owner, without resources (tenant-owner-label, LimitRange)
accepted, owner label set to team-a, memory limit 512Mi from the LimitRange
5. Outside tenant namespaces, nothing changes
accepted in default
```

Without a dry run, a compliant Deployment created in `demo` ran a pod labelled `platform.idplatformkit.io/owner=team-a`. The existing tenant's namespace got its new labels from the composition, without being re-created.

**First attempt: the owner label on pod templates failed.** The `MutatingPolicy` first had autogen for Deployments and the other workload kinds, like the validating one. For a Deployment, Kyverno 1.19 evaluated the mutation without rewriting its types, and refused every Deployment in tenant namespaces:

```
Policy tenant-owner-label: failed to evaluate policy: type mismatch: unexpected type name "Object.metadata", expected "Object.spec.template.metadata"
```

The mutation now applies to Pods only, with autogen off. Pods created by Deployments and Jobs still get the label, because they go through admission as well.

**Argo CD saw Kyverno as OutOfSync right after syncing it.** Its `policies.kyverno.io` CRDs stayed `OutOfSync` after a successful server-side apply. A server-side dry-run diff of the rendered CRD against the live one showed no difference. With `argocd.argoproj.io/compare-options: ServerSideDiff=true` on the Application, Argo CD compares the same way, and Kyverno is `Synced`.

## Limits

- No exceptions mechanism yet: a team that needs one (for example a privileged debug pod) has none. Kyverno's `PolicyException` and a reviewed pull request would be the way.
- Violations are only visible at admission time. Kyverno's policy reports aren't shown in the portal yet.
- Images aren't checked: no signature verification and no allowed registries.
