# Block C — instructor answer key

> **Don't read this before attempting the You-do.** The value is in building the image yourself and watching the layer cache behave.

## What success looks like

By the end of Block C, the participant has:

1. Built the gateway image with `scripts/build-image.sh`, tagged `:sha-<short>` + `:local`.
2. Run the image with **no bind mounts** and seen `example-project` load at the test port — the self-contained proof.
3. Baked a module/config change into the image and confirmed it via `docker run … cat modules.json` (no running gateway).
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

## Failure-case discussion (Part 4)

Breaking the build on purpose is the cheap, high-value lesson: **image-based moves failures left.** A bad `COPY` path, malformed JSON the build depends on, or a missing module file fails the *build* — on a free hosted runner, before any gateway is touched. In Lab 04 the same class of mistake shipped files onto a live gateway and you found out at scan time (or worse, at runtime). Tie this to `ci.yml`'s no-push build smoke test: the PR fails, not prod.

## Stretch notes

- **`docker history --no-trunc`.** Largest layer is almost always the base image, then third-party modules. The `projects/` layer is tiny. Good prompt: "if projects were 500 MB of assets, would you still bake them, or mount them / pull at runtime?" There's no single right answer — it's the trade-off that matters.
- **Multi-stage.** Right answer: you don't need it here (IA image is the runtime, we only copy files). You'd add a builder stage to compile a custom module or run tooling you don't want in the shipped image.

## Bridge to Block D

The image exists locally. Block D pushes it to a registry and deploys it. Foreshadow the two questions Block D answers:

1. *Where does the image go, and who's allowed to push/pull it?* (GHCR + `GITHUB_TOKEN`.)
2. *How do you ship the same image you tested to prod?* (Build-once / promote-many — re-tag, don't rebuild.)
