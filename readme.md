# Kasten K10 → Harbor Image Mirror

Two scripts that pull every container image for a given Kasten K10 version
from Google's public registry and push them into a private Harbor project,
for air-gapped / restricted-network K10 installs:

- `kasten-harbor-mirror.sh` — uses **podman**
- `kasten-harbor-mirror-docker.sh` — uses **docker**

Both behave identically. Pick whichever engine is installed on your host.

## What it does

1. Logs in to your Harbor registry
2. Pulls `k10tools:<version>` and asks it for the full list of images used
   by that K10 release
3. Pulls each of those images from `gcr.io`
4. Retags each one under your Harbor project (e.g.
   `gcr.io/kasten-images/kanister-tools:9.0.1` →
   `harbor.apps.openshift2.lab.home/kasten-images/kanister-tools:9.0.1`)
5. Pushes the retagged images to Harbor

You'll be asked to confirm three times along the way: once before logging
in, once before the (potentially multi-GB) pull, and once before the push.
A full log of every command's output is written to a tempfile
(`/tmp/kasten-harbor-mirror.XXXXXX.log`), path shown at the end of the run.

## Prerequisites

- `podman` or `docker` installed and working
- Network access to `gcr.io` and to your Harbor instance
- A Harbor project to push into (see below)
- A `.credentials` file (see below)

## 1. Create the Harbor project

The scripts push into a Harbor **project**, not just a bare registry — this
needs to exist before you run them; Harbor won't auto-create it on push.

1. Log in to the Harbor web console as an account with permission to
   create projects (e.g. `https://harbor.apps.openshift2.lab.home`)
2. **Projects → New Project**
3. **Project Name**: `kasten-images` (must match `HARBOR_PROJECT` in the
   script — see customisation below if you want a different name)
4. **Access Level**: Private is recommended, unless you want the images
   world-readable
5. Leave storage quota as default unless you have a reason to cap it — a
   full K10 image set is typically a few GB
6. **OK** to create

Make sure the account in your `.credentials` file has at least
**push/pull (Developer or higher)** permission on that project. Project
admins can check/add this under **Projects → kasten-images → Members**.

## 2. Create the credentials file

The scripts read Harbor credentials from a file (default: `.credentials`,
same directory you run the script from):

```
your-harbor-username
your-harbor-password-or-cli-secret
```

- Line 1: username
- Line 2: password (for Harbor's local auth) or the user's **CLI secret**
  (Profile → User Profile in Harbor) if you're using OIDC/LDAP login —
  CLI secret is generally preferred since it doesn't expire with your SSO
  session
- No trailing blank lines needed, but harmless if present

Lock the permissions down since it's a plaintext credential file:

```bash
chmod 600 .credentials
```

If you use git for this directory, add it to `.gitignore` so it never
gets committed:

```bash
echo ".credentials" >> .gitignore
```

You can point at a different file/location without editing the script:

```bash
CRED_FILE=/path/to/other-file ./kasten-harbor-mirror.sh
```

## 3. Run it

```bash
chmod +x kasten-harbor-mirror.sh   # or the -docker.sh variant
./kasten-harbor-mirror.sh
```

You'll be prompted for the K10 version (e.g. `9.0.1`) — everything else
is either hardcoded or read from `.credentials`.

### Docker-specific note

Docker has no per-command TLS-skip flag like podman's `--tls-verify=false`.
If your Harbor cert is self-signed/internal-CA, add the registry to
Docker's insecure-registries list first:

```bash
sudo tee /etc/docker/daemon.json <<'JSON'
{ "insecure-registries": ["harbor.apps.openshift2.lab.home"] }
JSON
sudo systemctl restart docker
```

(merge the key in rather than overwrite if you already have a
`daemon.json` with other settings). The docker script checks for this on
startup and will warn you if the registry isn't listed.

## Customising

All of the following are constants near the top of the script:

| Variable | Default | What it controls |
|---|---|---|
| `REGISTRY` | `harbor.apps.openshift2.lab.home` | Destination Harbor hostname |
| `HARBOR_PROJECT` | `kasten-images` | Destination project — must already exist in Harbor (see step 1) |
| `UPSTREAM_HOST` | `gcr.io` | Where K10 images are pulled from — only change this if Veeam moves their public registry |
| `CRED_FILE` | `.credentials` | Path to the credentials file — overridable via env var without editing the script |

To point at a different registry or project, edit both:

```bash
REGISTRY="registry.example.com"
HARBOR_PROJECT="my-other-project"
```

The destination path is always built as
`${REGISTRY}/${HARBOR_PROJECT}/<image-name>:<tag>`, so changing
`HARBOR_PROJECT` alone is enough to redirect uploads to a different
Harbor project on the same registry — no other logic depends on the
literal string `kasten-images`.

### Running against multiple registries/projects

Since these are just shell variables, the easiest way to keep several
configurations without maintaining separate script copies is a wrapper,
e.g.:

```bash
#!/bin/bash
# mirror-to-staging.sh
REGISTRY="harbor-staging.example.com" \
HARBOR_PROJECT="kasten-staging" \
CRED_FILE=".credentials-staging" \
./kasten-harbor-mirror.sh
```

That requires promoting `REGISTRY` and `HARBOR_PROJECT` to `${VAR:-default}`
form in the script (same pattern already used for `CRED_FILE`) if you want
to override them via environment variables instead of editing the file
directly — happy to make that change if you'll be juggling more than one
target regularly.

## Troubleshooting

- **`dial tcp: lookup ... no such host`** — DNS issue on your machine, not
  the script. Check `nslookup <registry-hostname>` resolves to the right
  IP against the DNS server you expect.
- **`received unexpected HTTP status: 503`** on login — you're likely
  hitting a route that doesn't serve the registry API (e.g. a `ui.`
  console route instead of the registry hostname). Confirm with:
  `curl -sk -o /dev/null -w "%{http_code}\n" https://<host>/v2/` — a
  `401` means you've got the right endpoint (just unauthenticated), a
  `503`/`404` means you don't.
- **x509 / certificate errors (docker only)** — add the registry to
  `insecure-registries` as described above.
- **Login succeeds but push fails with `unauthorized`** — the account in
  `.credentials` doesn't have push permission on the `kasten-images`
  project in Harbor; check project membership.
