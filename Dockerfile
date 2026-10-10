# ---------------------------------------------------------------------------
# Stage 1: install production dependencies only, from the lockfile
# ---------------------------------------------------------------------------
FROM node:22-slim AS deps

WORKDIR /srv
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
 && npm cache clean --force

# ---------------------------------------------------------------------------
# Stage 2: minimal runtime, non-root
# ---------------------------------------------------------------------------
FROM node:22-slim AS runtime

# Build metadata - supplied by CI (cloudbuild.yaml) and baked into the image,
# so a given image digest always reports the same build info.
ARG APP_VERSION=0.0.0-dev
ARG GIT_COMMIT=unknown
ARG GIT_BRANCH=unknown
ARG BUILD_TIME=unknown
ARG BUILD_ID=unknown

ENV NODE_ENV=production \
    APP_NAME=build-info-api \
    APP_VERSION=${APP_VERSION} \
    GIT_COMMIT=${GIT_COMMIT} \
    GIT_BRANCH=${GIT_BRANCH} \
    BUILD_TIME=${BUILD_TIME} \
    BUILD_ID=${BUILD_ID}

# OCI labels: the same metadata is visible to `docker inspect` / Artifact Registry
LABEL org.opencontainers.image.title="build-info-api" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_TIME}"

WORKDIR /srv
COPY --from=deps /srv/node_modules ./node_modules
COPY package.json ./
COPY src/ ./src/

# Fixed non-root UID matching the pod securityContext (runAsUser: 10001).
# Files stay root-owned (read-only to the app); rootfs is read-only in k8s anyway.
USER 10001:10001
EXPOSE 8080

# Run node directly (not `npm start`) so node is PID 1 and receives SIGTERM.
CMD ["node", "src/server.js"]
