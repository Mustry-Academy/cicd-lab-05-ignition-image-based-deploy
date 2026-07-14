# Mustry Academy — Lab 05 (image-based deploy)
#
# This Dockerfile bakes the *deployable state* of an Ignition gateway into an
# immutable, versioned image:
#
#   - project content        (projects/)
#   - gateway config          (services/config/)
#   - module enablement       (services/modules.json)
#   - third-party modules     (third-party-modules/*.modl)
#
# Contrast with Lab 04 (file-based): there, the same files were `docker cp`-ed
# into a *running* gateway and picked up by a hot scan. Here the files become
# layers in an image. You deploy by pulling the image and recreating the
# container — no scan, no live mutation. The image you test in dev is the exact
# image you promote to prod (same digest).
#
# Why modules belong in the image: a project scan can hot-reload views, scripts,
# and config, but it CANNOT enable/disable modules — that needs a gateway
# restart. Baking modules into the image is how image-based deploy earns its keep
# over file-based (the payoff Lab 04's Block B stretch teased).
#
# Build context is trimmed by .dockerignore so docs/exercises/scripts/.git never
# enter the build or the image.

# Pin the base image. Bump deliberately, not by floating `latest`.
ARG IGNITION_VERSION=8.3.6
FROM inductiveautomation/ignition:${IGNITION_VERSION}

# Where the gateway keeps its runtime state inside the container.
ARG GATEWAY_DATA_PATH=/usr/local/bin/ignition/data

# --- Bake the deployable state into image layers ----------------------------
# Each COPY is its own layer, so unchanged inputs stay cached on rebuild.
# Project content changes most often → keep it last so a project edit doesn't
# bust the (larger, slower) module layer above it.

# 1. Third-party .modl binaries — large, rarely change. Mounted at runtime via
#    -Dignition.gateway.externalModulesFolder=/third-party-modules (see compose).
COPY third-party-modules/  /third-party-modules/

# 2. Module enablement manifest — which modules the gateway turns on at boot.
COPY services/modules.json ${GATEWAY_DATA_PATH}/modules.json

# 3. Gateway-level config (db connections, tag providers, api tokens…).
#    .dockerignore keeps the per-gateway parts OUT of this layer: config/local,
#    config/resources/local, the internal identity (user-source/default,
#    user-source/opcua-module, identity-provider/default) and
#    security-properties — each gateway commissions its own identity from the
#    GATEWAY_ADMIN_* env vars at first boot instead.
COPY services/config/      ${GATEWAY_DATA_PATH}/config/

# 4. Project content (Perspective views, scripts, tags) — changes most often.
COPY projects/             ${GATEWAY_DATA_PATH}/projects/

# --- Provenance labels ------------------------------------------------------
# Stamp the image with the git SHA it was built from so you can always trace a
# running container back to a commit. CI passes --build-arg GIT_SHA=$(git ...).
ARG GIT_SHA=unknown
ARG IMAGE_SOURCE=https://github.com/mustry-academy/cicd-lab-05-ignition-image-based-deploy
LABEL org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.title="cicd-lab-05-ignition" \
      org.opencontainers.image.description="Ignition 8.3 gateway with baked-in project, config, and modules"

# The base image already defines ENTRYPOINT/CMD, EXPOSE 8088, and a healthcheck.
# We inherit them — there's nothing to override for a baked-state gateway.
