# Who can do what

Every way into the platform is a named identity with its own scope, and every credential that isn't tied to a person's sign-in expires. This page is the map.

## The matrix

| Identity | How it signs in | Kubernetes | Argo CD | OpenBao | Expires |
|---|---|---|---|---|---|
| **A team member** | GitHub, through Dex ([sso.md](sso.md)) | `edit` in the staging namespace of the team's tenants, `view` in prod: changes to prod go through pull requests ([environments.md](environments.md)) | Read | Role `tenant-<name>`: that tenant's secrets only, every environment | With the sign-in |
| **A platform admin** (`platform-admins` team) | GitHub, through Dex | `cluster-admin` (`platform/access/platform-admins.yaml`) | Admin | Role `admin`: everything | With the sign-in |
| **The portal** | Its pod's ServiceAccount token, `backstage-reader` | Read what it shows (including Argo CD Applications, for its admin page), no Secrets | – | – | Rotated by Kubernetes |
| **An agent** (`make agent-kubeconfig NAME=…`) | A ServiceAccount in `idpk-agents` | Read, no Secrets (`platform/access/agents.yaml`) | – | – | 8 hours by default |
| **CI** (GitHub Actions of the org) | The job's GitHub OIDC token, audience `idplatformkit` | Read, no Secrets (`platform/access/ci.yaml`) | – | – | With the job |
| **Break-glass** (`make break-glass WHO=…`) | A client certificate, `break-glass:<who>` | `cluster-admin`, **audited** | Through kubectl | – | 1 hour |
| **A tenant's workloads** | Their ServiceAccount, through OpenBao's Kubernetes auth | What the team grants in its namespace | – | Their environment's secrets only, through its `SecretStore` | Rotated by Kubernetes |

Changes to the platform itself don't go through any of these: they're pull requests on the Orchestrator and instances repositories, merged by people, applied by Argo CD.

## The portal's admin page

Platform admins have an **Admin** page in the portal (`https://portal.127.0.0.1.nip.io/admin`): the installation (org, instances repository, portal image), a link to each tool with how to sign in, and every Argo CD Application's health and sync status. The portal's backend checks the signed-in user is in `platform-admins` on every request and refuses everyone else; it reads the Applications with `backstage-reader`, which is why that role can read `applications.argoproj.io` (and so can agents and CI, which share it). Applications carry no secrets. Details in the portal's README.

## Agents

An agent sees the platform and never changes it directly. Every ServiceAccount in the `idpk-agents` namespace gets the portal's read-only view: tenants, databases, what they compose, their status, and no Secrets.

```sh
make agent-kubeconfig NAME=reviewer                        # .idpk/agents/reviewer.kubeconfig, 8 hours
make agent-kubeconfig NAME=reviewer AGENT_TOKEN_DURATION=1h
KUBECONFIG=.idpk/agents/reviewer.kubeconfig kubectl get tenants
```

To change something, an agent does what a person does: it opens a pull request on the instances repository, with its own GitHub identity (a GitHub App or a fine-grained token limited to that repository), and a person merges it. The platform's MCP server (M9) builds on this.

## CI

GitHub Actions workflows of the installation's org sign in with the OIDC token GitHub gives every job: no kubeconfig and no token stored in CI secrets. The API server trusts GitHub's issuer (`local/authentication-config.yaml`) for the audience `idplatformkit`, and only for repositories of the installation's org (`claims.repository_owner`). The user is `github-actions:<owner>/<repo>`, in the `github-actions` group, read-only.

```yaml
permissions:
  id-token: write
steps:
  - run: |
      token=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
        "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=idplatformkit" | jq -r .value)
      kubectl --token "$token" get tenants
```

This only works for a cluster GitHub's runners can reach. The local kind cluster isn't reachable from GitHub, so the e2e workflow checks it on the kind cluster it creates in the job (`make try-ci-identity`).

## Break-glass

For when single sign-on is down. Nobody holds a break-glass credential by default:

```sh
make break-glass WHO=anas      # .idpk/break-glass/anas.kubeconfig, cluster-admin for one hour
make break-glass-log           # what break-glass credentials did
```

`make break-glass` creates a key and a CertificateSigningRequest for `break-glass:<who>` in the `idpk:break-glass` group, approves it, and writes a kubeconfig. Kubernetes signs it for one hour (`expirationSeconds`). The `idpk:break-glass` group is bound to `cluster-admin` (`platform/access/break-glass.yaml`), and the API server's audit policy (`local/audit-policy.yaml`) logs every request from that group, and nothing else.

Argo CD's local `admin` account is disabled: in an emergency, use kubectl with a break-glass credential.

## What was actually observed

On kind (Kubernetes 1.36), fresh `make up` from this change:

- **Break-glass**: `make break-glass WHO=claude-test` wrote a kubeconfig (mode `600`) whose user is `break-glass:claude-test`, groups `idpk:break-glass`, `system:authenticated`; `auth can-i '*' '*'` → `yes`; the certificate was valid until one hour after issue. `make break-glass-log` then listed each request with its time, verb, resource and response code, including a ConfigMap created and deleted for the test; requests made with the cluster owner's admin certificate weren't logged.
- **Agents**: `make agent-kubeconfig NAME=check` → `system:serviceaccount:idpk-agents:check`; `get tenants` `yes`, `get secrets -n demo` `no`, `delete tenants` `no`, `create namespaces` `no`.
- **Portal**: no `backstage-reader-token` Secret anymore; `make backstage-token` returned a token for `backstage-reader` expiring 8 hours after issue.
- **Argo CD**: signing in as `admin` through the API returned `Invalid username or password`; `admin.enabled` is `false`.
- **CI**: in both e2e jobs, the job's OIDC token alone (`make try-ci-identity`, kubectl with no kubeconfig) signed in as `github-actions:idPlatformKit/Orchestrator`, group `github-actions`; `get tenants` `yes`, `get secrets -n kube-system` `no`, `create namespaces` `no`.

## What remains shared, and why

- **The kind cluster's admin certificate** (`kind-idplatformkit-local` in your kubeconfig) is the cluster owner's key, on their own machine: it creates the cluster and issues break-glass certificates. On a real cluster, it would be kept offline.
- **OpenBao's root token, `root-local-dev`**: dev mode requires one. The platform uses it to configure OpenBao (provider-vault), and `make try-tenant` to write a test secret. People sign in through Dex instead. A prod-like OpenBao, without a fixed root token, is M11 (#37).
