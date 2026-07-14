# Lab 05 — instructor answer key

> **Don't read this before attempting the You-do.** For part 1 the value is in building the image yourself and watching the layer cache behave. For part 2 the interesting content is the digest-equality proof and the rollback, not the click-path.

---

# Part 1 — Build the gateway image

## What success looks like

By the end of part 1, the participant has:

1. Built the gateway image with `scripts/build-image.sh`, tagged `:sha-<short>` + `:local`.
2. Run the image with **no bind mounts** and seen `example-project` load at the test port — the self-contained proof.
3. Baked a project change (the `description` in `project.json`) into the image and confirmed it via `docker run … cat project.json` (no running gateway).
4. Explained the Dockerfile's layer order as a cache strategy.
5. Extended `.dockerignore` and kept `scripts/validate.sh` green.
6. Traced an image back to its commit via the `org.opencontainers.image.revision` label.

If #2 or #3 is missing, push them to finish — those two are the whole "the image *is* the artifact" lesson.

## The four COPY lines, annotated

```dockerfile
COPY third-party-modules/  /third-party-modules/                       # big, rare → top
COPY services/modules.json /usr/local/bin/ignition/data/modules.json   # module enablement
COPY services/config/      /usr/local/bin/ignition/data/config/        # gateway config
COPY projects/             /usr/local/bin/ignition/data/projects/      # daily churn → bottom
```

Things to highlight in the grade:

- **modules.json is in the image.** This is the single biggest contrast with Lab 04. A participant who can articulate "a scan can't enable a module, but baking it + recreating the container can" has the core idea.
- **Layer order.** If they reordered `projects/` to the top "because it's the most important," that's the teachable miss — importance isn't the axis, *volatility* is. Most-volatile last keeps rebuilds cheap.
- **Paths match Lab 04's `docker cp` targets.** `data/projects` and `data/config` are the same dirs the file-based deploy wrote into. The difference is *when* (build time vs deploy time) and *mutability* (frozen layer vs live copy).

## The `.dockerignore`, annotated

The line that matters most is `.env`. Grade for whether they understand *why*: a careless future `COPY . .`, or even a misconfigured tool, would otherwise bake credentials into a published, pullable artifact. `.dockerignore` is the backstop, not just a speed optimization. The speed/cleanliness reasons (`.git/`, `docs/`) are secondary.

## Common stumbles

- **"My change isn't in the image."** They edited a file but it's matched by `.dockerignore`, or they edited under a path the Dockerfile doesn't `COPY`. Have them run `docker run --rm --entrypoint find <image> /usr/local/bin/ignition/data` and look (the `--entrypoint` is required — the IA image treats trailing args as gateway arguments otherwise).
- **"Every build rebuilds everything."** They're editing a top layer's input (e.g. `third-party-modules/`), or Docker's cache was cleared. Show `CACHED` vs not in the build output and tie it to which file they touched.
- **"It won't build — not found in build context."** A `COPY` source typo or a `.dockerignore` pattern that's too broad. The error names the path; read it.
- **"The standalone `docker run` won't come up."** Missing `-e ACCEPT_IGNITION_EULA=Y`, or they didn't wait for the JVM. It's slower than they expect.
- **Confusing the build context with the image.** The context is what's *sent* to the daemon; the image is what the `COPY`s *select* from it. `.dockerignore` shrinks the former; the Dockerfile selects the latter.

## Failure-case discussion

Breaking the build on purpose is the cheap, high-value lesson: **image-based moves failures left.** A bad `COPY` path, malformed JSON the build depends on, or a missing module file fails the *build* — on a free hosted runner, before any gateway is touched. In Lab 04 the same class of mistake shipped files onto a live gateway and you found out at scan time (or worse, at runtime). Tie this to `ci.yml`'s no-push build smoke test: the PR fails, not prod.

## Stretch notes

- **`docker history --no-trunc`.** Largest layer is almost always the base image, then third-party modules. The `projects/` layer is tiny. Good prompt: "if projects were 500 MB of assets, would you still bake them, or mount them / pull at runtime?" There's no single right answer — it's the trade-off that matters.
- **Multi-stage.** Right answer: you don't need it here (IA image is the runtime, we only copy files). You'd add a builder stage to compile a custom module or run tooling you don't want in the shipped image.

## Bridge to part 2

The image exists locally. Part 2 deploys it by recreating the container; the repo's CI workflows extend the same flow through a registry. Foreshadow the two questions that flow answers:

1. *Where does the image go, and who's allowed to push/pull it?* (GHCR + `GITHUB_TOKEN`.)
2. *How do you ship the same image you tested to prod?* (Build-once / promote-many — re-tag, don't rebuild.)

---

# Part 2 — Deploy the image

## What success looks like

By the end of part 2, the participant has:

1. The bundled `github-runner` online in their fork (`self-hosted, lab05`).
2. Two GitHub environments (`lab-gateway-dev`, `lab-gateway-prod`) — typically with **no** secrets/variables (GHCR auth is `GITHUB_TOKEN`; `IGNITION_URL` defaults are fine).
3. Merged a PR **into `main`** → watched `deploy.yml`'s `build` (hosted) push to GHCR and `deploy` (self-hosted) recreate dev. Change live on :8089.
4. Pushed a `v*` tag on `main` → watched `release.yml` promote `:dev` (no rebuild) and recreate prod. Change live on :8090.
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

### GitHub flow framing (why we promote `:dev`, not a rebuild)

This lab is **GitHub flow**: a merge to `main` → dev gateway, a `vX.Y.Z` tag on `main` → prod gateway. The subtlety worth teaching: `release.yml` does **not** rebuild from the tagged commit — it promotes the **`:dev` image** (what dev is running). That's the honest definition of a release: *ship what dev validated*. Tagging is the freeze point: you tag when dev is where you want prod to be. If a participant asks "why not just rebuild from the tag?" — that breaks build-once/promote-many: a rebuild could pull a newer base layer and ship bytes dev never tested.

## The digest-equality proof

This is the money moment. After a release:

```bash
docker inspect -f '{{ index .RepoDigests 0 }}' lab05-ignition-dev
docker inspect -f '{{ index .RepoDigests 0 }}' lab05-ignition-prod
```

Same `sha256:…`. If a participant shrugs, ask: *"What would it take for these to differ, and why would that scare you?"* Answer: a rebuild for prod could pull a newer base layer or a non-deterministic dependency — prod would run something dev never tested. Build-once/promote-many makes that impossible by construction.

> If `.RepoDigests` is empty for a locally-built image (no registry digest yet), use the CI-deployed images, or compare `docker inspect -f '{{.Image}}'` (the local image ID) instead.

## Rollback

The canonical image-based rollback: *re-promote a previous tag.* `release.yml`'s `workflow_dispatch` takes a `tag` input; running it with `v0.1.0` re-tags that **existing** image to `:prod` and recreates prod. No rebuild, no `git revert`, no history surgery.

Have them compare to Lab 04, where rolling prod back meant re-copying old files and re-scanning — more steps, more partial-state risk, and nothing immutable to point at. The grade question: *"How many irreversible steps are in each rollback path?"* Image-based: zero (you're pointing at an artifact that already exists).

## Common stumbles

- **#1 by far — nothing happens after merge.** Forks ship with **Actions disabled**; the participant never enabled them (Actions tab → "I understand my workflows…"). No CI, no build, no push. Check this first whenever "the workflow didn't run." Worth saying up front in Part 2.1.
- **"Can I even push? It's your registry."** Reassure: the build publishes to *their own* `ghcr.io/<their-fork-owner>/…` (the workflow derives the namespace from `github.repository_owner`), never to Mustry's. Nothing in the lab pushes to a registry they don't own. Good moment to show them the package appearing under *their* fork → Packages.
- **403 pushing, org-owned fork.** If their fork is under a GitHub org, *Settings → Actions → General → Workflow permissions* must be **read and write**, and org Packages must be enabled. Personal forks are fine by default. (Plain `permissions: packages: write` is already in the workflow.)
- **401 pulling on the deploy job.** No `docker login ghcr.io` before `docker pull`. The package is private by default; the runner must authenticate.
- **`manifest unknown` on release.** No `:dev` image exists yet — they tagged a release before ever shipping anything to dev. Fix: push to `main` so `deploy.yml` publishes `:dev`, then tag. (On a rollback dispatch, it means that version was never released.) See TROUBLESHOOTING.
- **Duplicate stack from the runner.** Compose project name mismatch — confirm the `name:` field is set in `docker-compose.yaml`. Without it, the runner's checkout dir name becomes the project and it spins up a parallel set.
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
