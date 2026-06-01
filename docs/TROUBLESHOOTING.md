# Troubleshooting

Quick fixes for the things that bite people during Blocks C and D. Work top to bottom; most issues
are one of the first three.

## The stack won't start / `scripts/setup.sh` fails

- **Docker isn't running or isn't Compose v2.** `docker compose version` must work (note the space —
  not `docker-compose`). Start Docker Desktop and re-run `scripts/setup.sh` (it's idempotent).
- **Not enough RAM.** Three gateways at 1 GB each + TimescaleDB + the runner need **≥ 8 GB free**.
  Raise Docker's memory or bump the per-gateway limit in [`docker-compose.yaml`](../docker-compose.yaml).
- **Port already in use.** 8088/8089/8090 (gateways) or 5432 (TimescaleDB). Stop the other process or
  change the host port mappings.

## A gateway never reaches RUNNING

- Give it time — a cold JVM start is 60–120 s per gateway, and an **image-based** boot re-commissions
  the gateway, so dev/prod can take a little longer than `local`.
- Check logs (use `docker logs` with the container name, not `docker compose logs`):
  ```bash
  docker logs --tail 200 lab05-ignition-dev     # or -local / -prod
  ```
- **Trial expired.** Each gateway runs in 2-hour trial mode. Reset via *Gateway → Config → Licensing →
  Reset Trial*. Note: recreating dev/prod from a fresh image resets their trial clock too.

## `docker build` / `scripts/build-image.sh` fails

- **"… not found in build context."** A `COPY` source path is wrong, or the path is excluded by
  [`.dockerignore`](../.dockerignore). Check the four `COPY` lines in the [`Dockerfile`](../Dockerfile)
  against what's actually on disk.
- **Context is huge / build is slow.** Something big is in the context. `du -sh .git` is the usual
  culprit — confirm `.git/` is in `.dockerignore`. Build with `--progress=plain` to see the transfer size.
- **Image builds but is missing a file.** It's almost always `.dockerignore` excluding something you
  meant to bake. Verify with `docker run --rm --entrypoint find <image> /usr/local/bin/ignition/data/projects`
  (the `--entrypoint` is required — the IA image otherwise treats trailing args as gateway arguments).

## Gateway FAULTs: "unable to create resource dir … /.resources"

You ran the image with `docker run` but **without `--user root`**. The baked config/project files
are root-owned, and the gateway needs to create runtime directories under `data/config/` at boot —
which it can't do as the default non-root user. Add `--user root` (the lab's `docker-compose.yaml`
sets `user: root` on every gateway for exactly this reason). It's a useful reminder that **file
ownership is part of what an image carries**. Full working stand-alone command is in
[`exercises/block-c.md`](../exercises/block-c.md) and printed by `scripts/build-image.sh`.

## Gateway stuck in `RUNNING / COMMISSIONING` (stand-alone run)

A bare `docker run` is missing the commissioning env vars, so the gateway waits on the setup wizard.
Add `-e IGNITION_EDITION=standard` and `-e GATEWAY_ADMIN_USERNAME=admin` (plus `ACCEPT_IGNITION_EULA=Y`
and `GATEWAY_ADMIN_PASSWORD`). The compose stack supplies all of these already, so deploys via
`deploy.yml` / `scripts/deploy-image.sh` don't hit this — it's only a stand-alone-run gotcha.

## GHCR push/pull fails (401 / 403 / denied)

- **403 on push from the build job.** The workflow needs `permissions: packages: write` (it's set in
  `deploy.yml` / `release.yml`). If you copied a job without it, add it.
- **401 on pull from the deploy job.** The deploy job must `docker login ghcr.io` with `GITHUB_TOKEN`
  before `docker pull` — confirm the *Log in to GHCR* step is present and ran.
- **`denied: permission_denied` / wrong namespace.** GHCR paths must be lowercase. The workflow
  lowercases the owner; if you hand-edited the image name, check the casing.
- **Pulling locally (outside CI).** A private package needs `docker login ghcr.io` with a PAT that has
  `read:packages`. Or make the package public in its settings.

## `manifest unknown` when releasing

`release.yml` promotes `:sha-<short>` of the **tagged commit**. If that image was never built, the
re-tag fails with `manifest unknown`. Cause: you tagged a commit that hadn't been pushed to `main`
and deployed yet. Fix: get the commit onto `main` (so `deploy.yml` builds its `:sha-…` image), then
push the tag — or re-run `release.yml` once the build exists.

## The deploy ran but my change isn't visible

- **Right gateway?** `local` = :8088 (your authoring gateway, file-based), `dev` = :8089, `prod` = :8090.
- **Which image is it running?**
  ```bash
  docker inspect -f '{{.Config.Image}}' lab05-ignition-dev
  ```
  If it still shows `inductiveautomation/ignition:8.3.6`, the deploy didn't recreate it — the
  `IGNITION_DEV_IMAGE` override wasn't set. Re-run the deploy, or locally:
  `scripts/deploy-image.sh dev <image>`.
- **Stale moving tag.** If you deployed `:dev` by name and it didn't change, remember moving tags can
  point at an old digest on a host that already cached them. Deploy the immutable `:sha-<short>` tag.

## dev/prod stuck on the base image (empty gateway)

That's the **default** until the first deploy — `IGNITION_DEV_IMAGE` / `IGNITION_PROD_IMAGE` are unset,
so compose falls back to the base Ignition image. Run `deploy.yml` (push to main) / `release.yml`
(tag), or locally `scripts/build-image.sh && scripts/deploy-image.sh dev cicd-lab-05-ignition:local`.

## The self-hosted runner is offline / jobs queue forever

- Container up? `docker compose ps github-runner` and `docker logs lab05-runner` (look for
  *"Listening for Jobs"*).
- `RUNNER_REPO_URL` must point at **your fork**; `RUNNER_GITHUB_PAT` must be a real `repo`-scoped PAT.
  After editing `.env`: `docker compose restart github-runner`.
- In your fork: *Settings → Actions → Runners* should list it online with `self-hosted, lab05`.

## The runner recreates the WRONG containers (a duplicate stack appears)

The deploy job runs `docker compose up -d ignition-dev` from the runner's checkout. If a parallel set
of containers shows up, the Compose **project name** didn't match. This lab pins it with `name: lab05`
at the top of `docker-compose.yaml` — confirm that line is present and unchanged.

## `git status` shows dozens of `config.json` / `resource.json` changes

Ignition rewrites these on every interaction. The repo ships a git hook that marks them
`skip-worktree`; `scripts/setup.sh` installs it. If you see the churn:

```bash
scripts/setup.sh
bash scripts/git-hooks/skip-worktree-ignition-resources
```

## Validate before you push

```bash
scripts/validate.sh      # JSON + .dockerignore + hadolint + actionlint — mirrors CI
scripts/build-image.sh   # confirm the image actually builds
```

Still stuck? The instructor answer keys ([block-c-key.md](../instructor-notes/block-c-key.md),
[block-d-key.md](../instructor-notes/block-d-key.md)) have deeper failure-mode walkthroughs.
