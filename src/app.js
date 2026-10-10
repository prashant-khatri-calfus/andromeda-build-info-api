/**
 * Build Info API.
 *
 * Reports *what* is running and *where*:
 *  - Build metadata (version, git commit, branch, build time, CI build id) is
 *    baked into the image at build time via Docker build args -> env vars, so
 *    the answer is immutable for a given image and traceable to a commit.
 *  - Runtime metadata (pod, namespace, node) is injected by Kubernetes via the
 *    Downward API, so you can tell which replica answered.
 */
import os from 'node:os';
import Fastify from 'fastify';

export const UNKNOWN = 'unknown';
const STARTED_AT = Date.now();

const env = (name, fallback = UNKNOWN) => {
  const value = (process.env[name] ?? '').trim();
  return value || fallback;
};

export const getBuildInfo = () => ({
  app_name: env('APP_NAME', 'build-info-api'),
  version: env('APP_VERSION', '0.0.0-dev'),
  git_commit: env('GIT_COMMIT'),
  git_branch: env('GIT_BRANCH'),
  build_time: env('BUILD_TIME'),
  build_id: env('BUILD_ID'),
});

export const getRuntimeInfo = () => ({
  environment: env('ENVIRONMENT', 'local'),
  pod_name: env('POD_NAME', os.hostname() || UNKNOWN),
  pod_namespace: env('POD_NAMESPACE'),
  node_name: env('NODE_NAME'),
  node_version: process.version,
  uptime_seconds: Math.floor((Date.now() - STARTED_AT) / 1000),
});

// JSON schema for the response: validates/serialises output (fast-json-stringify)
// and documents the contract.
const str = { type: 'string' };
const buildInfoSchema = {
  response: {
    200: {
      type: 'object',
      required: ['build', 'runtime', 'timestamp'],
      properties: {
        build: {
          type: 'object',
          required: ['app_name', 'version', 'git_commit', 'git_branch', 'build_time', 'build_id'],
          properties: {
            app_name: str,
            version: str,
            git_commit: str,
            git_branch: str,
            build_time: str,
            build_id: str,
          },
        },
        runtime: {
          type: 'object',
          properties: {
            environment: str,
            pod_name: str,
            pod_namespace: str,
            node_name: str,
            node_version: str,
            uptime_seconds: { type: 'integer' },
          },
        },
        timestamp: str,
      },
    },
  },
};

/**
 * Pino options so logs land in Cloud Logging with the right severity:
 * one JSON object per line, `severity` instead of numeric `level`,
 * `message` instead of `msg`.
 */
const loggerOptions = (level) => ({
  level,
  messageKey: 'message',
  formatters: {
    level: (label) => ({ severity: label.toUpperCase() }),
  },
  base: undefined, // drop pid/hostname noise
  timestamp: () => `,"time":"${new Date().toISOString()}"`,
});

export function buildApp({ logger = true } = {}) {
  const app = Fastify({
    logger: logger ? loggerOptions(env('LOG_LEVEL', 'info').toLowerCase()) : false,
  });

  app.get('/', async () => ({ service: getBuildInfo().app_name, see: '/build-info' }));

  app.get('/build-info', { schema: buildInfoSchema }, async () => ({
    build: getBuildInfo(),
    runtime: getRuntimeInfo(),
    timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
  }));

  // Liveness: the process is up and the event loop responds.
  // Probes log only warnings+ so kubelet checks don't flood the logs.
  const quiet = { logLevel: 'warn' };

  app.get('/healthz', quiet, async () => ({ status: 'ok' }));

  // Readiness: safe to receive traffic. No downstream dependencies today; this
  // is where DB/cache checks would go. Separate from liveness so a failing
  // dependency removes the pod from the Service instead of restarting it.
  app.get('/readyz', quiet, async (_req, reply) => {
    if (process.env.FORCE_NOT_READY === 'true') {
      return reply.code(503).send({ status: 'not-ready' });
    }
    return { status: 'ready' };
  });

  return app;
}
