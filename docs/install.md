# Install IdPlatformKit

IdPlatformKit always runs on **your own GitHub org**, with **your own instances repository**. The org's members sign in to the portal, its teams own the tenants, and the repository holds every claim. The `idPlatformKit` org is just one installation, the one the project uses for its demo.

```sh
git clone https://github.com/idPlatformKit/Orchestrator.git && cd Orchestrator
make setup    # checks your machine, prepares your GitHub org (interactive)
make up       # builds the platform on kind
```

Then open **https://portal.127.0.0.1.nip.io** and sign in with GitHub.

## What you need

- Docker running (Docker Desktop, OrbStack, Colima…), `kind` v0.32 or later, `kubectl`, `helm`, `openssl`, `git`, `curl`, and the GitHub CLI `gh`, signed in. Optional: [kubelogin](https://github.com/int128/kubelogin), for kubectl as yourself (`make kubeconfig-sso`).
- Host ports 80 and 443 free: the platform serves `https://<name>.127.0.0.1.nip.io` there, on `127.0.0.1` only.
- A **GitHub org** you own, with **at least one team**. A free org is enough: create one at https://github.com/account/organizations/new. Use a test org if you're only trying IdPlatformKit.

`make setup` checks all of this and says what's missing, with the command or link to fix it.

## `make setup`

An interactive script (`scripts/setup.sh`), safe to re-run: it offers to keep what's already configured.

1. **Tools**: each prerequisite, Docker running, ports 80 and 443 free.
2. **GitHub access**: `gh` signed in, with the scopes the portal needs to import your org's members and teams (`read:org`, `read:user`, `user:email`). `gh`'s default token lacks `read:user` and `user:email`: the script offers to add them (`gh auth refresh`, in the browser).
3. **Your org**: picked among yours. The script checks you're an owner, and warns if the org has no team, since a tenant is owned by a team.
4. **Your instances repository**: created from [idPlatformKit/instances-template](https://github.com/idPlatformKit/instances-template), empty and **public** (Argo CD reads it anonymously on this local install), or reused if it exists.
5. **The portal's OAuth App**: GitHub has no API to create one, so the script opens the org's "new OAuth App" page and prints the three values to paste:

   | Field | Value |
   |---|---|
   | Application name | `IdPlatformKit portal` |
   | Homepage URL | `https://portal.127.0.0.1.nip.io` |
   | Authorization callback URL | `https://portal.127.0.0.1.nip.io/api/auth/github/handler/frame` |

   Then it asks for the client ID and secret (typed hidden).
6. **Dex's OAuth App**, the same way: Argo CD and kubectl sign you in through Dex, which needs its own OAuth App (homepage `https://dex.127.0.0.1.nip.io`, callback `https://dex.127.0.0.1.nip.io/callback`). Step 3 also offers to create a **`platform-admins`** team with you in it: its members administer the platform. See [sso.md](sso.md).

It writes everything to **`.idpk.env`**: git-ignored, readable by you only (`600`), and read by the Makefile.

## `make up`

Creates the kind cluster, installs Argo CD and the bootstrap Secrets, then lets Argo CD install everything else from Git and sync **your** instances repository. At the end it runs `make status`:

```
IdPlatformKit status

  ✓ GitHub org idpk-test, claims in https://github.com/idpk-test/instances
  ✓ Argo CD: every application Synced and Healthy
  ✓ Portal running
  ✓ Local CA trusted by this machine

Open
  Portal    https://portal.127.0.0.1.nip.io   sign in with GitHub (a member of idpk-test)
  Argo CD   https://argocd.127.0.0.1.nip.io   admin / <generated password>
  OpenBao   https://openbao.127.0.0.1.nip.io/ui   token root-local-dev
```

If the local CA isn't trusted yet, `make status` says so: run `make local-ca-trust` once per machine (sudo), so the browser accepts the platform's certificate.

Without a configuration, `make up` stops with "run make setup first": nothing falls back to the demo org.

## Your first tenant

1. In the portal: **Create → New Tenant**. Pick a name, one of your org's teams, and optionally an OpenBao secrets space.
2. The template opens a pull request on your instances repository, **under your own GitHub identity**. Its CI validates the claim against the platform's APIs.
3. Merge it. Argo CD syncs it within about 3 minutes, Crossplane creates the tenant, and the portal's catalog shows it within 5 minutes, with a Kubernetes tab listing its resources.

## Where the configuration goes

| Value | Used by |
|---|---|
| `IDPK_GITHUB_ORG`, `IDPK_INSTANCES_REPO` | The root Application's values (`bootstrap/root-app.yaml`): the `instances` Application syncs `https://github.com/<org>/<repo>.git`, the `portal` Application passes them to the portal |
| `AUTH_GITHUB_CLIENT_ID`, `AUTH_GITHUB_CLIENT_SECRET` | The `portal-secrets` bootstrap Secret (`make portal-secret`), never in Git |
| `DEX_GITHUB_CLIENT_ID`, `DEX_GITHUB_CLIENT_SECRET` | The `dex-secrets` bootstrap Secret (`make dex-secret`), never in Git |
| Your `gh` token (or `GITHUB_TOKEN`) | Same Secret: the portal's catalog imports the org's members and teams with it |

The portal runs in the cluster from the published image `ghcr.io/idplatformkit/portal`, through the `platform/portal/` chart, used by both install flows. Nothing in the portal names an org: see its [README](https://github.com/idPlatformKit/portal#one-installation-one-org).

## What was actually observed

On a new org, `idpk-test`, on macOS with OrbStack (the local CA was already trusted on that machine):

- `make setup` detected the `gh` token's missing scopes, created `idpk-test/instances` from the template, and wrote `.idpk.env` with mode `600`.
- `make up` on a fresh cluster: every Application `Synced`/`Healthy` in 4.5 minutes. The `instances` Application synced `https://github.com/idpk-test/instances.git`; the portal imported the org (1 user, 1 team) and discovered the repository.
- Signing in through the org's OAuth App, then New Tenant: idpk-test/instances#1 opened under the user's identity, its CI passed, and after the merge the tenant was `Ready`, with its `RoleBinding` granting `edit` to the org's team and its OpenBao `SecretStore` `Valid`. The portal showed it with all its resources in the Kubernetes tab, read with the pod's own ServiceAccount.

**The first pull request failed with `Not Found`.** The template's last step returned `HttpError: Not Found` on GitHub's create-blob endpoint. GitHub's response showed the user's token only had `read:user`: asking for `public_repo` at template time had only refreshed the sign-in token, without opening GitHub's consent screen. The portal now requests `public_repo` at sign-in. Details in the [portal README](https://github.com/idPlatformKit/portal#sign-in-asks-for-public_repo).

## Limits

- The instances repository must be public on this local install. A private one needs repository credentials in Argo CD.
- GitHub only. GitLab is planned in [#46](https://github.com/idPlatformKit/Orchestrator/issues/46).
- Like the rest of the platform: local dev credentials, single replicas, an in-memory portal catalog that's rebuilt from GitHub on every restart. A reference setup, not production.
