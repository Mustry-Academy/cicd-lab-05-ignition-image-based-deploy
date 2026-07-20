# Image-based deploy pattern — cheat sheet

Reference reading for part 2 of the lab. The complete pattern in five steps, build-once/promote-many, GHCR auth, rollback, and where image-based fits versus file-based.

## The pattern in five steps

```
┌──────────┐    ┌────────┐    ┌─────────┐    ┌────────┐    ┌─────────────┐
│ 1. Build │ →  │ 2. Tag │ →  │ 3. Push │ →  │ 4. Pull│ →  │ 5. Run      │
│  image   │    │ :sha + │    │ to GHCR │    │ on the │    │ (recreate   │
│ from     │    │ moving │    │         │    │ target │    │  container) │
│ Dockerfile│   │ tag    │    │         │    │        │    │             │
└──────────┘    └────────┘    └─────────┘    └────────┘    └─────────────┘
```

1. **Build** the image from the `Dockerfile`, baking projects/config/modules into layers.
2. **Tag** it `:sha-<short>` (immutable) and a moving pointer (`:dev` or `:prod`).
3. **Push** to the registry (GHCR).
4. **Pull** the image on the machine that owns the target gateway.
5. **Run** — `docker compose up -d ignition-<env>` recreates the container from the new image.

Then verify health. No SSH of files, no scan API — the image already contains the state; you replace the whole container.

In this lab **steps 4 and 5 are yours to type.** CI does 1–3 and prints the tag; you pull it and point the gateway at it. Steps 4–5 are exactly what a self-hosted runner would do on your behalf, which is what Labs 06 and 07 set up.

## Build-once, promote-many

The single most important idea in image-based release:

```
push to main ──▶ build ──▶ :sha-abc1234 + :dev ──▶ deploy to dev  (test it here)
                                       │
tag v0.1.0 (on main) ─▶ promote ───────┘ re-tag :dev ──▶ :v0.1.0 + :prod ──▶ deploy to prod
                        (no rebuild — same digest)
```

`release.yml` does **not** rebuild on a tag. It runs `docker buildx imagetools create` to copy the manifest of the already-tested **`:dev`** image (the one dev is running) onto new tags (`:v0.1.0`, `:prod`). Server-side, no layers moved. (Why `:dev` and not a rebuild from the tagged commit? A rebuild could pull a newer base layer and ship bytes dev never ran — we promote *what dev validated*.) Prove it:

```bash
docker inspect -f '{{ index .RepoDigests 0 }}' lab05-ignition-dev
docker inspect -f '{{ index .RepoDigests 0 }}' lab05-ignition-prod
# the sha256:… digests are identical — prod runs the bytes dev tested
```

If you rebuilt for prod instead, a base-image update, a dependency, or a clock-dependent layer could differ — and you'd be shipping something dev never saw.

## Build is portable; deploy is not

| Step | Where it runs | Why |
|---|---|---|
| build, push | `ubuntu-latest` (GitHub-hosted, free) | Just needs Docker + registry creds. Nothing environment-specific. |
| pull, recreate | A machine that can reach the gateway's Docker daemon — **in this lab, your laptop, by hand** | Environment-specific and privileged. Cannot run on a shared hosted runner. |

This split is the operational payoff over file-based. In Lab 04 a self-hosted runner did *everything* — it held the working tree and ran `docker cp`. In the image world it would only do the last mile, because the build no longer needs to happen next to the gateway. Build minutes move to the free hosted pool; the privileged machine does less.

That's why this lab needs no runner at all: with the build off-box, what's left is two commands you can run yourself. Doing them by hand shows you precisely how small the privileged half of a deploy actually is.

## GHCR auth (least privilege)

- **Push** (build/promote jobs): the workflow requests `permissions: packages: write` and logs in with the built-in `GITHUB_TOKEN`. No PAT, no stored registry password.
- **Pull** (a deploy job, once you have one): log in with the same `GITHUB_TOKEN`. Pulling needs only `packages: read`, which `write` includes.
- **First push** creates the package in your fork's namespace, **private** by default. Pulling it by hand therefore needs a one-off `docker login ghcr.io`; flip the package public if you'd rather pull anonymously.
- **Don't** hand a deploy runner a broad PAT "to be safe." The job-scoped `GITHUB_TOKEN` is enough and expires with the run.

## File-based vs image-based: when each fits

| Concern | File-based (Lab 04) | Image-based (Lab 05) |
|---|---|---|
| Time to deploy | Seconds (cp + scan) | Minutes (build → push → pull → boot) |
| Hot reload? | Yes, for project changes | No — container restart |
| Module changes | Can't (scan won't apply) | Trivial — baked in |
| Atomic rollback | Hard (re-copy old files) | Easy (run the previous tag) |
| Promotion across envs | Re-copy per env | Re-tag the tested image |
| Privilege needed | Docker socket / filesystem on every deploy | Socket only for the last-mile recreate; build is off-box |
| Artifact you can audit | None (just git) | A versioned, labelled image with a digest |
| Best for | Active development, frequent project edits | Releases, module/baseline changes, immutable infra |

Most mature Ignition shops use **both**: file-based for the daily inner loop on a working gateway, image-based for promoting releases through dev → prod. This lab keeps `local` file-based (authoring) and makes dev/prod image-based (releases) so you live in both worlds at once.

## Rollback

Three patterns, increasing maturity — image-based makes the strong ones cheap:

1. **`git revert` + re-merge.** Triggers a fresh build/deploy of the reverted state. Works, but rebuilds.
2. **Re-promote a known-good tag.** `release.yml`'s `workflow_dispatch` takes a `tag` input: point prod at `v0.1.0`'s *existing* image in two clicks. No rebuild, no git surgery. This is the canonical image-based rollback.
3. **Keep N versions warm.** Because every release is an immutable tag in the registry, "roll back" is always available for any version you haven't deleted. Retention/cleanup of old tags becomes the real question (out of scope here).

## What lives where (and what's safe to throw away)

Image-based deploy recreates the container on every deploy, so be clear about what dies with it:

| In the image (dies on each deploy, comes back from the image) | Outside the image (persists) |
|---|---|
| Project content, config, module manifest + binaries | Historian data → TimescaleDB |
| The gateway's commissioned internal DB (re-created each boot) | Anything you deliberately put on an external volume or DB |

In this lab, dev/prod have **no persistent data volume** — that's intentional, and safe *only because* the durable data (historian) is in Timescale. In a real deployment you'd decide carefully what (if anything) needs a volume: gateway audit logs, alarm journal, named user accounts. Each is a "does this belong in the image, a volume, or a database?" decision.

## When NOT to do image-based

- **Sub-minute iteration on project content.** Rebuilding and rebooting for every view tweak is painful — use the file-based inner loop (`local` gateway) and only build an image when you're ready to release.
- **Stateful gateway data you can't externalize.** If critical state is trapped in the gateway's local DB and can't move to a volume/DB, recreating the container loses it. Fix the state location first.
- **No registry reachable from the target.** Image-based assumes the gateway host can pull. Truly air-gapped sites need a `docker save`/`load` sneakernet or a local registry mirror.

For releases, module/baseline changes, and anything you need to roll back atomically, image-based is the right default.
