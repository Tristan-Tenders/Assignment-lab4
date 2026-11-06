# Mission 3, step 3 - Multi-stage build. This is the Dockerfile used for v1, v2 and the pipeline.

# ---------- Stage 1: build (full toolchain + devDependencies) ----------
FROM node:20 AS build
ARG GITHUB_SHA=local-dev
ENV GITHUB_SHA=${GITHUB_SHA}
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---------- Stage 2: run (only what the app needs at runtime) ----------
FROM node:20-alpine AS run
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build --chown=node:node /app/server.js ./server.js
COPY --from=build --chown=node:node /app/public ./public
COPY --from=build --chown=node:node /app/dist/build-manifest.json ./dist/build-manifest.json
USER node
EXPOSE 4173
CMD ["node", "server.js"]
