# Block D — Deploy & promote the image

**Duration:** ~90 minutes
* 20 min demo
* 20 min we-do
* 40 min you-do
* 10 min debrief

## Goal

You should leave this block able to:

- Describe the image-based deploy pattern in five steps: **build → tag → push → pull → run (recreate)**.
- Deploy an image to a gateway manually and watch the container get replaced.
- Wire the flow into GitHub Actions so a push to `main` builds and deploys to **dev**, and a tag push promotes to **prod**.
- Explain **build-once / promote-many**: prove the prod gateway runs the *exact same image digest* dev tested.
- Roll back prod to a previous release by re-running the release with an older tag.

## Pre-flight

```bash
scripts/setup.sh
scripts/build-image.sh    # you'll deploy this image in the We-do
```

You'll need:

- **A fork of this repo on GitHub.** The bundled runner registers against your fork, and images push to *your* GHCR namespace.
- **A GitHub Personal Access Token with `repo` scope** in `.env` as `RUNNER_GITHUB_PAT` (the runner uses it to auto-register).
- **No registry account and no API keys.** GHCR auth uses the workflow's built-in `GITHUB_TOKEN`; image-based deploy doesn't scan, so there's no `IGNITION_API_KEY` to manage for dev/prod.

Read ahead if you like: [`docs/image-based-deploy-pattern.md`](../docs/image-based-deploy-pattern.md).

## I do (20 min)

### The five steps

```
┌──────────┐   ┌────────┐   ┌────────┐   ┌────────┐   ┌─────────────┐
│ 1. Build │ → │ 2. Tag │ → │ 3. Push│ → │ 4. Pull│ → │ 5. Run      │
│  image   │   │ :sha + │   │ to GHCR│   │ on the │   │ (recreate   │
│          │   │ :dev   │   │        │   │ runner │   │  container) │
└──────────┘   └────────┘   └────────┘   └────────┘   └─────────────┘
```

Contrast with Lab 04's five steps (checkout → prune → ship → scan → verify): there the artifact was *files* and the gateway stayed alive. Here the artifact is an *image* and the gateway is replaced.

### Build is portable; deploy is local

Sketch the topology on the board:

```
   ┌──────────────┐  build+push   ┌──────────────────────────┐
   │ GitHub Actions│ ───────────▶ │  ghcr.io  (your namespace)│
   │ ubuntu-latest │              │  :sha-<short>  :dev  :prod│
   └──────────────┘              └──────────────────────────┘
          │ needs(build)                      ▲
          ▼                                   │ docker pull
   ┌──────────────────────────────┐           │
   │ self-hosted runner (lab05)    │ ──────────┘
   │  docker compose up -d ign-dev │  recreates the dev/prod container
   └──────────────────────────────┘
```

The **build** runs anywhere (free GitHub-hosted runner). Only the **pull + recreate** needs the self-hosted runner, because that runner owns the gateway container. In Lab 04 *everything* needed the self-hosted runner (it did the `docker cp`). Moving the build off it is a real operational win.

### Promote, don't rebuild

When you tag a release, `release.yml` does **not** build again. It re-tags the image dev already tested:

```bash
docker buildx imagetools create \
  --tag <repo>:v0.1.0 --tag <repo>:prod \
  <repo>:sha-<short>          # ← the exact image dev ran
```

Same digest, server-side copy, no layers moved. Prod runs *the bytes you tested*, not a fresh build that might differ.

## We do (20 min)

Deploy the image you built in pre-flight to the **dev** gateway, manually — this is what `deploy.yml` automates.

1. Confirm dev is currently on the **base** image (empty gateway):
   ```bash
   docker inspect -f '{{.Config.Image}}' lab05-ignition-dev
   ```
2. Recreate dev from your local build:
   ```bash
   scripts/deploy-image.sh dev cicd-lab-05-ignition:local
   ```
   Watch it pull (nothing to pull — it's local), recreate the container, and wait for `RUNNING`.
3. Verify in http://localhost:8089 — the `example-project` is now there. No `docker cp`, no scan. The container was *replaced*.
4. Confirm which image it runs:
   ```bash
   docker inspect -f '{{.Config.Image}}' lab05-ignition-dev
   ```
5. Note what *persisted*: the historian data in TimescaleDB is untouched. The gateway container was thrown away and rebuilt, but the data that matters lives in the database, not the image.

## You do (40 min)

### Part 1 — Verify the runner is up (5 min)

```bash
docker compose ps github-runner
docker compose logs --tail 50 github-runner   # look for "Listening for Jobs"
```

In your fork, *Settings → Actions → Runners* should show it online with `self-hosted, lab05`. If not: `RUNNER_REPO_URL` must point at your fork, `RUNNER_GITHUB_PAT` must be a real `repo`-scoped PAT, then `docker compose restart github-runner`.

### Part 2 — GitHub environments (10 min)

In your fork:

1. *Settings → Environments → New environment*: `lab-gateway-dev`.
2. Create `lab-gateway-prod` the same way.

You usually **don't** need to set any secret or variable — GHCR auth uses the built-in `GITHUB_TOKEN`, and `IGNITION_URL` defaults to the in-compose service name. The environments still earn their keep: per-stage deploy history, and a place to add **required reviewers** on prod (Part 5 stretch).

> No `IGNITION_API_KEY` here — that was a Lab 04 thing. Image-based deploy replaces the container instead of scanning it.

### Part 3 — Trigger `deploy.yml` (15 min)

1. Open a PR that touches a baked input — e.g. change a Perspective view under `projects/example-project/com.inductiveautomation.perspective/views/…`.
2. Watch [`ci.yml`](../.github/workflows/ci.yml) run on `ubuntu-latest`: JSON, hadolint, actionlint, **and a no-push image build** (so a broken Dockerfile fails here).
3. Merge to `main`. [`deploy.yml`](../.github/workflows/deploy.yml) fires.
4. Watch the two jobs:
   - **`build`** (GitHub-hosted): builds and pushes `:sha-<short>` + `:dev` to GHCR. Check *your fork → Packages* — a new `cicd-lab-05-ignition` package appears.
   - **`deploy`** (self-hosted): pulls that image and recreates the dev gateway.
5. Verify in http://localhost:8089 — your view change is live. Then confirm the image:
   ```bash
   docker inspect -f '{{.Config.Image}}' lab05-ignition-dev   # ghcr.io/<you>/…:sha-<short>
   ```

### Part 4 — Trigger `release.yml` and prove build-once/promote-many (10 min)

```bash
git checkout main && git pull
git tag v0.1.0
git push origin v0.1.0
```

[`release.yml`](../.github/workflows/release.yml) fires:
- **`promote`** re-tags `:sha-<short>` → `:v0.1.0` + `:prod` (no rebuild).
- **`deploy`** recreates the prod gateway from `:prod`.

Now prove prod runs **the same bytes** dev tested — compare digests:

```bash
docker inspect -f '{{ index .RepoDigests 0 }}' lab05-ignition-dev
docker inspect -f '{{ index .RepoDigests 0 }}' lab05-ignition-prod
```

The `sha256:…` digests match (the tags differ; the content doesn't). That equality is the whole promise of image-based promotion — you ship what you tested.

### Part 5 — Roll back (5 min)

Make a second release so you have something to roll back *from*: edit a view, merge, `git tag v0.2.0 && git push origin v0.2.0`. Prod now runs `v0.2.0`. Then roll back **without touching git history**:

- *Actions → Release → Run workflow*, set the `tag` input to `v0.1.0`.
- `promote` re-tags `v0.1.0`'s image to `:prod`; `deploy` recreates prod from it.
- Verify prod reverted (the view is back to the v0.1.0 state).

This is the image-based rollback button: *run the previous tag*. Compare the effort to Lab 04, where rollback meant re-copying old files and re-scanning.

## Definition of done

You're finished with Block D when:

- [ ] The runner shows **online** in your fork (`self-hosted, lab05`).
- [ ] Both environments (`lab-gateway-dev`, `lab-gateway-prod`) exist.
- [ ] A merged PR ran `deploy.yml`, pushed an image to your GHCR namespace, and the change is live on **dev** (:8089).
- [ ] A `v*` tag ran `release.yml` and the change is live on **prod** (:8090).
- [ ] You proved dev and prod run the **same image digest** after a release.
- [ ] You rolled prod back to an earlier tag via `workflow_dispatch`.
- [ ] You can explain the five steps and why build is portable but deploy is not.

## Stretch challenge `[OPTIONAL]`

- **Approval gate.** Add a required reviewer to `lab-gateway-prod` (*Settings → Environments → lab-gateway-prod → Required reviewers*). Push a tag and watch the `deploy` job *wait* for approval. No workflow change needed — that's the point of environments.
- **Rollback math.** You rolled back in two clicks. In Lab 04, what would rolling back prod have taken? Write the sequence of steps for each and compare the failure surface.
- **Make the package public.** Under the GHCR package settings, flip it to public, then `docker pull` the image from a machine that's never logged in. When would you *not* want that?

## Debrief (10 min)

- `deploy.yml` deploys an *immutable* `:sha-<short>` tag, but also pushes a *moving* `:dev` tag. Why deploy the immutable one and not `:dev`?
- The `deploy` step is `docker compose up -d ignition-dev` — atomic-ish: the old container runs until the new one is ready, then swaps. Compare to Lab 04's `rm -rf` + `docker cp`, which left a window of partial state. Which failure modes does image-based remove entirely?
- Historian data survived every deploy. List everything that's in the image (and dies with the container) versus everything that's in TimescaleDB (and persists). Where would *gateway audit logs* or *user accounts* fall, and what does that imply for a real deployment?
- The runner has the Docker socket. That's lab-grade, not production-grade. In a real customer setup, how would the "pull + recreate" step reach a gateway you're not allowed to give socket access to? (Think: a pull-based agent on the gateway host, or an orchestrator like Kubernetes/Swarm.)
