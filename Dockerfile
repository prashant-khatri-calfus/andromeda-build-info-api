FROM node:22-slim

WORKDIR /app

# Dependencies first, so this layer is cached until package*.json changes.
COPY package*.json ./
RUN npm ci --omit=dev

COPY src/ ./src/

# Build information, passed in by Cloud Build and baked into the image.
ARG APP_VERSION=dev
ARG GIT_COMMIT=unknown
ARG GIT_BRANCH=unknown
ARG BUILD_TIME=unknown
ARG BUILD_ID=unknown
ENV NODE_ENV=production \
    APP_VERSION=$APP_VERSION \
    GIT_COMMIT=$GIT_COMMIT \
    GIT_BRANCH=$GIT_BRANCH \
    BUILD_TIME=$BUILD_TIME \
    BUILD_ID=$BUILD_ID

# Run as the image's built-in non-root user (uid 1000).
USER node
EXPOSE 8080

# Start node directly (not `npm start`) so it receives SIGTERM and shuts down cleanly.
CMD ["node", "src/server.js"]
