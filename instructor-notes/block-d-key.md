# Block D — instructor answer key

> **Don't read this before attempting the You-do.** The interesting content is the digest-equality proof and the rollback, not the click-path.

## What success looks like

By the end of Block D, the participant has:

1. The bundled `github-runner` online in their fork (`self-hosted, lab05`).
2. Two GitHub environments (`lab-gateway-dev`, `lab-gateway-prod`) — typically with **no** secrets/variables (GHCR auth is `GITHUB_TOKEN`; `IGNITION_URL` defaults are fine).
3. Merged a PR → watched `deploy.yml`'s `build` (hosted) push to GHCR and `deploy` (self-hosted) recreate dev. Change live on :8089.
4. Pushed a `v*` tag → watched `release.yml` re-tag (no rebuild) and recreate prod. Change live on :8090.
5. **Proved dev and prod run the same image digest** after a release.
6. Rolled prod back to an earlier tag via `workflow_dispatch`.

If #5 is missing, push them to do it — it's the conceptual centerpiece. #6 is the second-most important.

## The five-step pattern, walked through

Use on the board if they need a re-walk:

1. **Build** — `docker build` bakes projects/config/modules (hosted runner).
2. **Tag** — `:sha-<short>` (immutable) + `:dev` (moving).
3. **Push** — to GHCR with `GITHUB_TOKEN`.
4. **Pull** — the self-hosted runner pulls the immutable `:sha-<short>`.
5. **Run** — `docker compose up -d ignition-dev` recreates the container from it.

Contrast explicitly with Lab 04's checkout → prune → ship → scan → verify. The artifact changed (files → image) and the gateway lifecycle changed (mutate-in-place → replace).

## The two-job structure, annotated

```yaml
jobs:
  build:                    # runs-on: ubuntu-latest  (FREE, portable)
    permissions: { packages: write }   # GHCR push via GITHUB_TOKEN
    outputs: { image: <base>:sha-<short> }
    # login → buildx → build-push-action (push: true) → cache to gha
  deploy:                   # needs: build
    runs-on: [self-hosted, lab05]      # owns the gateway container
    environment: lab-gateway-dev       # history + optional gates
    # login → docker pull <image> → docker compose up -d ignition-dev → smoke-check
```

Things to highlight in the grade:

- **The build/deploy split.** The single biggest operational difference from Lab 04. Build minutes are free and off the privileged runner; only the last-mile recreate needs `self-hosted`. A participant who can explain *why* you'd want that split (cost, blast radius, the runner does less) gets the lesson.
- **`needs: build` + the `image` output.** The deploy job consumes the exact tag the build produced. Deploying the immutable `:sha-…` (not `:dev`) is deliberate — moving tags drift.
- **`permissions: packages: write`.** Least privilege for the registry, no PAT. The deploy job only needs read (included in write).
- **`concurrency` + `cancel-in-progress: false`.** Don't cancel a deploy mid-recreate; queue the next one.
- **`environment:`.** Even empty, it buys per-stage deploy history and the place to bolt on required reviewers for prod.

`release.yml` is the same shape but the first job is **promote, not build** — `imagetools create` re-tags the tested image. Make sure they notice it does **not** rebuild.

## The digest-equality proof (Part 4)

This is the money moment. After a release:

```bash
docker inspect -f '{{ index .RepoDigests 0 }}' lab05-ignition-dev
docker inspect -f '{{ index .RepoDigests 0 }}' lab05-ignition-prod
```

Same `sha256:…`. If a participant shrugs, ask: *"What would it take for these to differ, and why would that scare you?"* Answer: a rebuild for prod could pull a newer base layer or a non-deterministic dependency — prod would run something dev never tested. Build-once/promote-many makes that impossible by construction.

> If `.RepoDigests` is empty for a locally-built image (no registry digest yet), use the CI-deployed images, or compare `docker inspect -f '{{.Image}}'` (the local image ID) instead.

## Rollback (Part 5)

The canonical image-based rollback: *re-promote a previous tag.* `release.yml`'s `workflow_dispatch` takes a `tag` input; running it with `v0.1.0` re-tags that **existing** image to `:prod` and recreates prod. No rebuild, no `git revert`, no history surgery.

Have them compare to Lab 04, where rolling prod back meant re-copying old files and re-scanning — more steps, more partial-state risk, and nothing immutable to point at. The grade question: *"How many irreversible steps are in each rollback path?"* Image-based: zero (you're pointing at an artifact that already exists).

## Common stumbles

- **403 pushing to GHCR.** Missing `permissions: packages: write`, or they removed the GHCR login step. The build job logs name it.
- **401 pulling on the deploy job.** No `docker login ghcr.io` before `docker pull`. The package is private by default; the runner must authenticate.
- **`manifest unknown` on release.** They tagged a commit whose `:sha-…` image was never built (tagged before it hit main + deployed). Fix: deploy that commit first, then tag. See TROUBLESHOOTING.
- **Duplicate stack from the runner.** Compose project name mismatch — confirm `name: lab05` in `docker-compose.yaml`. Without it, the runner's checkout dir name becomes the project and it spins up a parallel set.
- **"Deploy ran but dev didn't change."** They deployed `:dev` (moving) and the host had an old digest cached, or `IGNITION_DEV_IMAGE` wasn't set. Inspect `{{.Config.Image}}` on the container.
- **`Context access might be invalid` / environment warnings in the IDE.** Cosmetic — the Actions VS Code extension can't verify environments/vars that don't exist on GitHub yet. Gone once the environments are created.
- **Expecting a hot reload.** Someone edits a view and expects dev to update without a deploy. That's the *local* gateway's job (file-based). Dev/prod only change when an image is deployed. This confusion is worth surfacing — it's exactly the file-vs-image boundary.

## Debrief talking points

- **Immutable vs moving tags.** Deploy `:sha-<short>`, navigate with `:dev`/`:prod`. A participant who'd `docker compose up` with `:dev` pinned in prod has a footgun — moving tags drift under you.
- **Atomicity.** Image recreate keeps the old container until the new one is ready, then swaps. Lab 04's `rm -rf` + `docker cp` had a partial-state window. Image-based deletes that failure mode.
- **What persists.** Historian → Timescale (survives). Everything in the image dies and is reborn each deploy. Push them to place user accounts / audit logs / alarm journal in that mental model — each is a "image vs volume vs database" decision in a real deployment.
- **Socket = lab-grade.** The runner has the Docker socket. In production you wouldn't hand that out; you'd use a pull-based agent on the gateway host or an orchestrator. Good segue to the multi-gateway lab.

## Wrap-up — set up the next day

- Stop the runner if they're pausing (`docker compose stop github-runner`); the PAT stays in `.env`.
- Foreshadow multi-gateway: "You promoted one image to one prod gateway. Next: the same image to *many* gateways, and how you coordinate that fan-out."
