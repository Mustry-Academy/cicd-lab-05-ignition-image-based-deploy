# Lab 05 — Ignition image-based deploy

Day 3 of the [CI/CD for Ignition Masterclass](https://github.com/mustry-academy/cicd-masterclass).

> Bake an Ignition gateway's project, config, **and modules** into a versioned Docker image, push it to a registry, and deploy by pulling the image and recreating the container — then promote the *exact same image* you tested in dev to prod on a tag, with rollback as easy as running a previous tag.

This is the companion to [Lab 04 (file-based deploy)](https://github.com/mustry-academy/cicd-lab-04-ignition-file-based-deploy). There you `docker cp`-ed files into a *running* gateway and triggered a hot scan — fast, great for daily project iteration, but it couldn't touch modules (a scan can't enable/disable them) and gave you no versioned, rollback-able artifact. Image-based deploy is the other half: the deployable state becomes an immutable image. Most mature Ignition workflows use **both** — file-based for the inner loop, image-based for releases.

## What changes from Lab 04

| | Lab 04 (file-based) | Lab 05 (image-based) |
|---|---|---|
| Unit of deploy | Files on disk | A versioned image |
| Mechanism | `docker cp` + hot scan | `docker pull` + recreate container |
| Modules | Can't ship (scan won't apply) | Baked into the image |
| Rollback | Re-deploy old files | Run the previous tag |
| Promotion | Re-copy per environment | Re-tag the tested image |
| Where it shines | Active development | Immutable releases |

The local → dev → prod story is the same; only the dev/prod **delivery mechanism** changes.

## Prerequisites

- A fork of this repo. The self-hosted runner registers against your fork, and the CI builds publish images to **your own** GHCR namespace (`ghcr.io/<your-fork-owner>/cicd-lab-05-ignition`) — never to Mustry's. **Enable Actions in your fork first**: forks ship with workflows disabled — open the *Actions* tab and click the green "I understand my workflows, go ahead and enable them" button.
- A GitHub Personal Access Token with `repo` scope — the runner uses it to auto-register; never leaves your `.env`. **Reuse the one you created in Lab 04**; if you're starting here, make one at [github.com/settings/tokens](https://github.com/settings/tokens) (Generate new token → classic → tick `repo`).
- **≥ 8 GB free RAM for Docker** — three Ignition gateways at 1 GB each, plus TimescaleDB, the runner, and Docker overhead.
- _Background:_ [Lab 04](https://github.com/mustry-academy/cicd-lab-04-ignition-file-based-deploy) sets up the Ignition stack and the file-based pattern this lab contrasts with. It helps but isn't required — this lab stands alone.
- _No extra registry account:_ the CI publishes to **GitHub Container Registry (GHCR)** under your fork, authenticated with the workflow's built-in `GITHUB_TOKEN`. The **local** scripts (`build-image.sh`/`deploy-image.sh`) need no registry at all — they build and run images on your machine.

## Quick start

```bash
gh repo clone mustry-academy/cicd-lab-05-ignition-image-based-deploy
cd cicd-lab-05-ignition-image-based-deploy
cp .env.example .env
scripts/setup.sh    # brings up the stack, waits for all three gateways, prints credentials
```

Once setup finishes you have three Ignition gateways:

| Gateway | URL | What runs there |
|---|---|---|
| `local` | http://localhost:8088 | Bind-mounted from `./projects/` + `./services/config/` — your **authoring** gateway (file-based, like Lab 04). |
| `dev` | http://localhost:8089 | The **image** `deploy.yml` builds on push to **`main`**. Base image (empty) until the first deploy. |
| `prod` | http://localhost:8090 | The **image** `release.yml` promotes on tag push `v*` (cut from `main`). Base image (empty) until the first release. |

Login with the credentials from `.env` (`GATEWAY_ADMIN_USERNAME_LOCAL/_DEV/_PROD`, default `admin / password`).

> **Trial mode:** each gateway runs in 2-hour trial mode. Reset via *Gateway → Config → Licensing → Reset Trial* — unlimited and legal for development. Note: because dev/prod are recreated from a fresh image on each deploy, their trial clock resets every deploy too.

> **Stuck?** See [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md). Before opening a PR, run `scripts/validate.sh` (mirrors CI) and `scripts/build-image.sh` (confirms the image builds).

## Lab structure

The lab is one exercise in two ordered parts — see [`exercises/lab.md`](./exercises/lab.md):

1. **Build the gateway image** — bake projects, config, and modules into a self-contained image.
2. **Deploy the image** — recreate the dev gateway from it, ship a change end-to-end, roll back.

Reference reading sits alongside: [`docs/dockerfile-anatomy.md`](./docs/dockerfile-anatomy.md) (part 1) and [`docs/image-based-deploy-pattern.md`](./docs/image-based-deploy-pattern.md) (part 2).



## Repo layout

```
cicd-lab-05-ignition-image-based-deploy/
├── README.md
├── Dockerfile                          ← bakes projects + config + modules into the gateway image
├── .dockerignore                       ← what NOT to send to the build context (the image-based .deployignore)
├── docker-compose.yaml                 ← three gateways + TimescaleDB + bundled self-hosted runner
├── .env.example                        ← copy to .env before running
├── .gitattributes                      ← JSON line-ending normalization + binary markers
├── .github/
│   ├── workflows/
│   │   ├── ci.yml                      ← PR validation: JSON, hadolint, actionlint, build smoke test (ubuntu-latest)
│   │   ├── deploy.yml                  ← push to main → build+push image → recreate dev gateway
│   │   └── release.yml                 ← tag v* (on main) → re-tag the dev image → recreate prod gateway
│   ├── actionlint.yaml                 ← declares the self-hosted `lab05` runner label
│   └── pull_request_template.md
├── exercises/
│   └── lab.md                          ← the lab, in two ordered parts: build the image, then deploy it
├── db-init/                            ← timescaledb init: create ignition_dev + ignition_prd databases
├── docs/                               ← reference reading
│   ├── dockerfile-anatomy.md
│   ├── image-based-deploy-pattern.md
│   └── TROUBLESHOOTING.md
├── instructor-notes/                   ← answer key (read after solo work)
│   └── lab-key.md
├── scripts/
│   ├── setup.sh                        ← bootstraps the whole stack
│   ├── teardown.sh                     ← stop the stack (with --volumes to wipe)
│   ├── build-image.sh                  ← local mirror of the CI build (build + tag)
│   ├── deploy-image.sh                 ← local mirror of the CI deploy (recreate a gateway from an image)
│   ├── trigger-scan.sh                 ← scan the LOCAL gateway (the file-based inner loop)
│   ├── validate.sh                     ← mirrors CI (JSON, .dockerignore, hadolint, actionlint)
│   ├── lib.sh                          ← shared helpers
│   ├── clean-ignition-resource-churn.sh ← undo volatile-only resource.json rewrites (dry-run / --apply)
│   ├── git-diff/                       ← textconv normalizer that hides volatile metadata in diffs
│   └── git-hooks/                      ← skip-worktree hooks for the machine-local config file
├── projects/                           ← project content (baked into the image; bind-mounted into `local`)
│   └── example-project/                ← a real Perspective project (views, templates)
├── services/
│   ├── config/                         ← gateway-level config (baked into the image)
│   └── modules.json                    ← module enablement (baked into the image — this is the Lab 04 payoff)
└── third-party-modules/                ← bundled .modl binaries (baked into the image)
```

## The Compose stack

Three Ignition 8.3 gateways + one TimescaleDB, simulating local → dev → prod:

- **`ignition-local`** bind-mounts `./projects/` and `./services/config/`, exactly like Lab 04. This is where you **author** content. The image you ship is *built from these same files*.
- **`ignition-dev`** runs whatever image `IGNITION_DEV_IMAGE` points at (default: the base Ignition image — an empty gateway). It has **no bind mounts and no persistent data volume** — the container filesystem *is* the artifact. `deploy.yml` sets `IGNITION_DEV_IMAGE` to the freshly built tag and recreates the container.
- **`ignition-prod`** is the same shape, fed by `release.yml` with the *promoted* image (the same one dev tested).

The single TimescaleDB hosts `ignition_loc`/`ignition_dev`/`ignition_prd`. **Historian data lives in Timescale, not in the gateway image** — which is exactly why throwing away and recreating the dev/prod container on every deploy is safe.

`name: cicd-lab05` at the top of the compose file pins the project name so the self-hosted runner — which checks the repo out into its own working directory — recreates *these* containers instead of a parallel set.

## Branching model (GitHub flow)

This lab uses **GitHub flow**: one long-lived branch, releases cut by tagging — the same flow as every previous lab.

```
feature/*  ──PR→  main ──push→  deploy.yml ──build+push→ :dev image ──→ DEV gateway
                   │
                   └─tag vX.Y.Z→  release.yml ──promote :dev→ :vX.Y.Z+:prod ──→ PROD gateway
```

| Branch | Role | What CI does |
|---|---|---|
| `main` | The only long-lived branch — every merge should be deployable | `deploy.yml` builds the image and ships it to the **dev** gateway |
| `feature/*` | Day-to-day work, branched off `main` | `ci.yml` validates the PR into `main` |
| tag `vX.Y.Z` | A release — stamp the `main` state you want in prod | `release.yml` promotes the tested image to **prod** |

**Releasing is promotion, not a rebuild.** `release.yml` promotes **the image dev already
tested** — the `:dev` tag — re-tagging it to `:vX.Y.Z` + `:prod`. Prod runs the exact digest dev
validated; rebuilding from the tagged commit could silently pull a newer base layer and ship bytes
dev never ran. Tag when dev is where you want prod to be.

## The CI/CD workflows

Three workflows under [`.github/workflows/`](./.github/workflows/):

| File | Trigger | Runner(s) | Purpose |
|---|---|---|---|
| [`ci.yml`](./.github/workflows/ci.yml) | PR to `main` | `ubuntu-latest` | Validate JSON + `.dockerignore`, lint the Dockerfile (hadolint) and workflows (actionlint), and **build the image** (no push) so a broken Dockerfile fails the PR. |
| [`deploy.yml`](./.github/workflows/deploy.yml) | Push to `main` (build paths), manual | `build`: `ubuntu-latest`<br>`deploy`: `[self-hosted, lab05]` | Build + push the image to GHCR (`:sha-<short>`, `:dev`), then pull it and recreate the **dev** gateway. |
| [`release.yml`](./.github/workflows/release.yml) | Tag `v*` (on `main`), manual | `promote`: `ubuntu-latest`<br>`deploy`: `[self-hosted, lab05]` | Re-tag the **`:dev`** image (what dev is running) to `:vX.Y.Z` + `:prod` (**no rebuild**) and recreate the **prod** gateway. |

The **build is portable** (free GitHub-hosted runner); only the **pull + recreate** needs the self-hosted runner that owns the gateway container. That split is the heart of image-based deploy.

### GHCR auth and environments

- The build/promote jobs push to **your own fork's** namespace — the workflows derive `ghcr.io/<owner>/cicd-lab-05-ignition` from `github.repository_owner`, so a student's fork publishes under *their* account, not Mustry's. No image ever pushes to a registry you don't own.
- Auth is the workflow's built-in `GITHUB_TOKEN` (the workflows request `packages: write`). No registry password in `.env`, no extra account. The deploy jobs log in with the same token to **pull**.
- The first push creates a GHCR package under your namespace. It defaults to **private**; that's fine — the runner authenticates. (Make it public under the package's settings if you want anonymous pulls.)
- If your fork lives under a GitHub **organization**, the org may restrict this: *Settings → Actions → General → Workflow permissions* must allow **read and write**, and Packages must be enabled. A 403 on push almost always traces back to one of these — see [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md).
- **No GHCR needed for the lab exercises** — the local `build-image.sh`/`deploy-image.sh` flow runs entirely on your machine. GHCR only enters via the CI workflows.

Each deploy job runs in a GitHub **environment** so you get per-stage history and optional gates:

| Environment | Used by | Optional variable | Default |
|---|---|---|---|
| `lab-gateway-dev` | `deploy.yml` | `IGNITION_URL` | `http://ignition-dev:8088` |
| `lab-gateway-prod` | `release.yml` | `IGNITION_URL` | `http://ignition-prod:8088` |

Add **required reviewers** on `lab-gateway-prod` for a manual approval gate before prod releases — common pattern, no workflow change.

The deploy part of [`exercises/lab.md`](./exercises/lab.md) walks through the deploy flow these workflows automate.

## Licence

Apache 2.0 — see [`LICENSE`](./LICENSE).
