# Block D — Deploy the image locally by replacing the container

**Duration:** ~90 minutes
* 15 min we-do
* 40 min you-do
* 10 min debrief

Everything in this block runs on your own machine. No fork with Actions, no PAT,
no registry account: a gateway image is ~2 GB, and uploading that from a course
laptop is not a good use of your hour. The registry legs of the pipeline (push +
pull) were covered in the teaching; here you do build, tag and run — the parts
where all the real mechanics live. Your local Docker image store plays the role
of the registry.

## Goal

You should leave this block able to:

- Deploy an image-based gateway by **recreating the container** from a new image — no `docker cp`, no scan call.
- Ship a change end-to-end by hand: edit → commit → rebuild → redeploy, and explain that this loop is exactly what a deploy pipeline automates.
- Roll a gateway back by **running the previous build's immutable tag**, and explain why versioned artifacts make that cheap.
- Say what survives a container-replace deploy (external DB data) and what does not (internal gateway state, trial clock, UI-made edits).

## Pre-flight

Block C finished: you have a built image tagged `:sha-<short>` + `:local`, and
`scripts/setup.sh` has the stack up (local gateway :8088, dev gateway :8089,
TimescaleDB).

## We-do (15 min)

Together, we deploy the Block C image to the dev gateway once:

1. **Before:** `docker inspect -f '{{.Config.Image}}' lab05-ignition-dev` — dev runs the plain base image (an empty gateway).
2. **Deploy:** `scripts/deploy-image.sh dev cicd-lab-05-ignition:local` — the script sets `IGNITION_DEV_IMAGE` and runs `docker compose up -d ignition-dev`; compose sees a new image and recreates the container.
3. **Verify:** http://localhost:8089 → example-project is there, plus the module change you baked in Block C. No copy, no scan: the container was **replaced**.
4. **After:** inspect again — dev now runs your image.
5. **What persisted:** historian data in TimescaleDB is untouched. The container died; the data that matters didn't live in it.

## You do (40 min)

### Part 1 — Deploy your image to dev (10 min)

Repeat the we-do yourself, from your own build:

1. Confirm which image dev runs (`docker inspect -f '{{.Config.Image}}' lab05-ignition-dev`).
2. `scripts/deploy-image.sh dev cicd-lab-05-ignition:local` and wait for RUNNING.
3. Verify at :8089 and inspect again.

### Part 2 — Ship a change end-to-end (15 min)

The full loop a pipeline automates. **Commit before you build** so each build
gets its own immutable `:sha` tag — that tag is your rollback point in Part 3.

1. Note the current build's `:sha-<short>` tag (`docker images cicd-lab-05-ignition`). Write it down.
2. Edit a Perspective view under `projects/example-project/…/views/` — make it visibly different (a title text works well).
3. Commit on a feature branch and merge to `main` (GitHub flow, like every lab):
   ```bash
   git checkout -b feature/tweak-view
   git add -A && git commit -m "Change overview title"
   git checkout main && git merge feature/tweak-view
   ```
4. Rebuild + redeploy:
   ```bash
   scripts/build-image.sh
   scripts/deploy-image.sh dev cicd-lab-05-ignition:local
   ```
5. Verify at :8089 — your change is live. `docker images` now shows **two** `:sha-…` tags: two deployable versions, both still on your machine.

### Part 3 — Roll back to the previous build (10 min)

1. Pretend Part 2's change broke something on dev. You need the previous version back, now.
2. Deploy the **old** tag you wrote down in step 1 of Part 2:
   ```bash
   scripts/deploy-image.sh dev cicd-lab-05-ignition:sha-<the-old-short-sha>
   ```
3. Verify at :8089 — the view is back to its previous state.
4. Count the irreversible steps you just took. (Zero: both versions still exist, and you can flip between them all afternoon.)

## Definition of done

- [ ] The dev gateway (:8089) runs **your** image, proven with `docker inspect`.
- [ ] You shipped a view change end-to-end: edit → commit → rebuild → redeploy → visible on dev.
- [ ] Your image store holds **two immutable `:sha` tags**, one per build, each traceable to its commit via the revision label.
- [ ] You rolled dev back to the older tag and verified the old view is live again.
- [ ] You checked that historian data survived both deploys, and can say why.
- [ ] You can name the two steps a production pipeline adds between your build and your run (push + pull), and why we skipped them today.

> **Fresh gateway alert.** Each deploy gave dev a brand-new gateway: new internal
> DB, new trial clock, gone are any UI-made edits. If that surprised you, good —
> that's the "fresh gateway" disadvantage from the teaching, experienced
> first-hand.

## Stretch challenge `[OPTIONAL]`

Two directions, pick by appetite:

1. **Go deeper on the image** (see the assignment slides): shrink the build
   context with `--progress=plain`, do layer forensics with
   `docker history --no-trunc`, or (if you have a fork with Actions) add a
   no-push `docker build` smoke-test job to `ci.yml` so a broken Dockerfile
   fails the PR.
2. **A first taste of Lab 06** — bake more kinds of cargo, the way the Wilms
   production image does:
   - **A third-party module:** enable an unused `.modl` from
     `third-party-modules/` in `services/modules.json`, rebuild, deploy to dev,
     find it under Config → Modules.
   - **A migrations folder:** create
     `db-migrations/0001_create_downtime_log.up.sql` with a simple
     `CREATE TABLE`, add a `COPY db-migrations/ /db-migrations/` layer, rebuild,
     and read the file back out of the image with `--entrypoint cat`. Nothing
     runs it yet — Lab 06 wires that up.
   - **An extra JAR:** add a `COPY` layer for a JAR the way Wilms ships its
     RabbitMQ client into `lib/core/gateway/`. Where in the layer order does it
     belong, and why?

## Debrief (10 min)

- File-based vs image-based, now that you've run both: which failure modes did you meet on each side, and what would you pick for your own plant?
- The rollback took one command. What made it that cheap? (Immutable tags: the previous version already exists as an artifact.)
- Each deploy was a fresh gateway. Which state at your plant could **not** survive that, and where would you move it (volume? external DB)?
- In production the image goes through a registry. What changes in the mechanics, and what stays exactly the same?
