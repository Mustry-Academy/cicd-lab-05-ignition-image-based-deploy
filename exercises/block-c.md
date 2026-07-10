# Block C — Build the gateway image

**Duration:** ~90 minutes
* 20 min demo
* 20 min we-do
* 40 min you-do
* 10 min debrief

## Goal

You should leave this block able to:

- Explain what an *image-based* gateway is: project, config, **and modules** baked into immutable Docker layers, versus files copied into a running gateway (Lab 04).
- Read the [`Dockerfile`](../Dockerfile) and say what each `COPY` puts where, and why the layer order is what it is.
- Read [`.dockerignore`](../.dockerignore) and explain why each pattern keeps the build context lean and secrets out of the image.
- Build the image, tag it `:sha-<short>` + `:local`, and run it **with no bind mounts** — proving the image is self-contained.
- Inspect the baked layers with `docker history` and trace a running container back to its commit.

## Pre-flight

```bash
scripts/setup.sh    # idempotent — safe even if the stack is already up
```

You'll need Docker with Compose v2 and ~8 GB free RAM. No GitHub setup yet — that's Block D. If you'd like to read ahead: [`docs/dockerfile-anatomy.md`](../docs/dockerfile-anatomy.md).

## We-do (20 min)

### The mental model

In Lab 04 the gateway was a long-lived, *mutable* thing: you copied files into its `data/` directory and asked it to scan. In image-based deploy the gateway is *immutable*: the deployable state is frozen into an image, and you deploy by replacing the whole container.

Both approaches deliver the same files to the same paths and achieve the same result. What changes is the trade-offs: file-based keeps the gateway alive (no restarts, fast inner loop) but you own the copy-and-delete logic; image-based gives you a frozen, versioned artifact with no copy scripts, but every deploy is a fresh gateway boot. This block is about experiencing the image side of that trade.

### Walk the Dockerfile

Open [`Dockerfile`](../Dockerfile). Four `COPY` lines bake the deployable state:

```dockerfile
FROM inductiveautomation/ignition:${IGNITION_VERSION}

COPY third-party-modules/  /third-party-modules/                       # large, rarely change
COPY services/modules.json /usr/local/bin/ignition/data/modules.json   # which modules turn on
COPY services/config/      /usr/local/bin/ignition/data/config/        # gateway config
COPY projects/             /usr/local/bin/ignition/data/projects/      # project content (changes most)
```

Two things to call out on the board:

1. **Where files land.** `data/projects/` and `data/config/` are the same paths Lab 04's `docker cp` targeted — Ignition scans them at startup. The difference is *when*: Lab 04 copied at deploy time into a running gateway; here they're present from the first boot.
2. **Layer order = cache strategy.** Docker caches each `COPY` layer keyed on its inputs. Order from least- to most-frequently-changed, so editing a Perspective view (bottom layer) doesn't bust the big modules layer above it. Rebuilds stay fast.

### Walk the .dockerignore

Open [`.dockerignore`](../.dockerignore). It's the image-based analogue of Lab 04's `.deployignore`: it controls what enters the **build context** — the tarball Docker hands the daemon before running the Dockerfile. Three reasons every excluded line matters:

- **Smaller/faster builds** — `docs/`, `exercises/`, `.git/` are megabytes Docker would otherwise upload and checksum on every build.
- **Cleaner image** — even though our `Dockerfile` only `COPY`s four things, a stray `COPY . .` in a future edit would drag in everything not ignored. Defence in depth.
- **No leaked secrets** — `.env` is excluded so credentials can never be baked into a published artifact. This is the line that matters most.

### Build it and run it standalone

```bash
scripts/build-image.sh          # builds, tags :sha-<short> and :local
docker history cicd-lab-05-ignition:local   # see the baked layers, newest on top
```

Now run the image **with no bind mounts** on a spare port — this is the proof that the image carries everything:

```bash
docker run --rm --user root -p 9088:8088 \
  -e ACCEPT_IGNITION_EULA=Y \
  -e IGNITION_EDITION=standard \
  -e GATEWAY_ADMIN_USERNAME=admin \
  -e GATEWAY_ADMIN_PASSWORD=lab05password \
  cicd-lab-05-ignition:local \
  -n demo -- -Dignition.allowunsignedmodules=true
# wait ~30–60s for "Starting project: example-project" in the log,
# then open http://localhost:9088 → the example-project is there
```

No `./projects` mount, no scan call — the project showed up because it's *inside the image*. Ctrl-C to stop (the `--rm` cleans it up).

> **Why `--user root`?** The files we baked are owned by root (that's how the build context copies them), and the gateway needs to create runtime dirs *under* `config/` on boot. The lab's `docker-compose.yaml` runs every gateway as `user: root` for the same reason. Drop `--user root` here and the gateway FAULTs with `unable to create resource dir … /.resources` — a good reminder that **file ownership is part of what you bake into an image**. The `IGNITION_EDITION` + `GATEWAY_ADMIN_USERNAME` vars let it auto-commission instead of waiting on the setup wizard.

## We do (20 min)

Together, build and dissect the image.

1. **Build with a real provenance stamp.** `scripts/build-image.sh` passes `--build-arg GIT_SHA=$(git rev-parse --short HEAD)`. Confirm it landed:
   ```bash
   docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
     cicd-lab-05-ignition:local
   ```
   That label is how you trace any running container back to the commit it was built from.

2. **Prove the layer cache.** Build once (done). Now touch a project file and rebuild — watch which layers say `CACHED`:
   ```bash
   touch projects/example-project/project.json
   scripts/build-image.sh
   ```
   The modules/config layers are `CACHED`; only the `projects/` layer (and anything after it) rebuilds. Then touch `third-party-modules/` instead and rebuild — notice *more* layers bust because that layer is higher up.

3. **See what `.dockerignore` kept out.** Compare the build context size with and without it:
   ```bash
   # what Docker would send WITHOUT .dockerignore (rough proxy):
   du -sh --exclude=.git .
   # the .git dir alone — excluded — is often the biggest single chunk:
   du -sh .git
   ```

4. **Read the image, not the repo.** List what actually got baked under `data/projects`. The
   Ignition base image's entrypoint treats any trailing args as *gateway* arguments, so to run a
   plain command you override it with `--entrypoint`:
   ```bash
   docker run --rm --entrypoint find cicd-lab-05-ignition:local \
     /usr/local/bin/ignition/data/projects -maxdepth 2
   ```
   It contains `example-project/` — and crucially *not* `README.md`, `docs/`, or `.env`, because `.dockerignore` kept them out of the context.

## You do (40 min)

### Part 1 — Bake a module-manifest change into the image (15 min)

Change what the gateway boots with by changing **the artifact**. Pick a module that's present in `third-party-modules/` but not yet enabled, and turn it on **through the image**.

1. Open [`services/modules.json`](../services/modules.json) and the compose `GATEWAY_MODULES_ENABLED` list to see what's available.
2. Enable one more module (edit `services/modules.json`, or confirm it's in the enabled list).
3. Rebuild: `scripts/build-image.sh`.
4. Prove it's baked in **without running a gateway** (override the entrypoint so the container runs
   `cat` instead of booting the gateway):
   ```bash
   docker run --rm --entrypoint cat cicd-lab-05-ignition:local /usr/local/bin/ignition/data/modules.json
   ```
   The change is in the image's layer: it is now part of the artifact. Every gateway that ever runs this image boots with it. No copy step to script, no file to forget.

### Part 2 — Extend `.dockerignore` and verify (10 min)

1. Add a throwaway file that should never reach the image: `echo secret > NOTES.local`.
2. Rebuild and check whether it leaked into the context. The cleanest check: add a temporary `COPY . /tmp/ctx` is overkill — instead reason about it. `NOTES.local` is **not** matched by any current pattern, so it *would* be in the context.
3. Add a pattern to `.dockerignore` (e.g. `*.local`) so it's excluded. Re-run `scripts/validate.sh` — the `.dockerignore` sanity check should still pass (your new pattern doesn't remove the required ones).
4. Delete `NOTES.local` when done.

### Part 3 — Give one build several tags, and trace it (10 min)

1. Build with an extra moving tag, the way a pipeline would tag `:dev`:
   ```bash
   scripts/build-image.sh --tag dev
   docker images cicd-lab-05-ignition
   ```
   You should see three tags pointing at the **same image ID**: `:sha-<short>`, `:local`, `:dev`. A tag is just a name. The immutable `:sha-…` name is what makes Block D's rollback trivial: every build keeps a name that never moves.
2. Pick the `:sha-<short>` tag and read its revision label back. Confirm it matches `git rev-parse --short HEAD`.

## Definition of done

You're finished with Block C when:

- [ ] `scripts/build-image.sh` builds the image and tags it `:sha-<short>` + `:local`.
- [ ] You ran the image **with no bind mounts** and saw `example-project` load — proving it's self-contained.
- [ ] You baked a module/config change into the image and confirmed it via `docker run --entrypoint cat … modules.json` (no running gateway needed).
- [ ] You can explain the Dockerfile's layer order in terms of cache busting.
- [ ] You extended `.dockerignore` and `scripts/validate.sh` still passes.
- [ ] You can trace a built image back to its commit via the `revision` label.

## Stretch challenge `[OPTIONAL]`

- **Shrink the context.** Run `docker build` with `--progress=plain` and watch the "transferring context" size. Add more to `.dockerignore` and watch it drop.
- **`docker history --no-trunc`.** Find which layer is largest. Is it the base image, the modules, or your project? What would you do differently if the project were 500 MB of assets?
- **Multi-stage thinking.** Our Dockerfile is single-stage because the IA base image is already the runtime. When *would* you want a builder stage? (Hint: compiling a custom module from source, or running a project linter that needs tools you don't want in the final image.)

## Debrief (10 min)

- The image is immutable, but the gateway still writes runtime state (internal DB, logs) at `data/`. Where does that go in our dev/prod setup, and why is it safe to throw away on each deploy? (Hint: look at what's *not* a volume in `docker-compose.yaml`, and where historian data lives.)
- We pin `inductiveautomation/ignition:8.3.6`, not `:latest`. Why does an immutable-artifact philosophy demand a pinned base?
- Lab 04's `.deployignore` was read by a shell loop in the workflow; Lab 05's `.dockerignore` is read by the Docker daemon. What does moving that responsibility *into the tool* buy you?
- In Block D this image gets pushed to a registry and deployed. What's the one tag you'd never want to deploy to prod by name, and why? (Foreshadow: moving vs. immutable tags.)
