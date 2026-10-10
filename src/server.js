import { buildApp, getBuildInfo } from './app.js';

const PORT = Number(process.env.PORT ?? 8080);
const HOST = process.env.HOST ?? '0.0.0.0';
const SHUTDOWN_TIMEOUT_MS = 20_000; // < terminationGracePeriodSeconds (30s)

const app = buildApp();

// Graceful shutdown: Kubernetes sends SIGTERM (after the preStop hook).
// app.close() stops accepting new connections and waits for in-flight requests.
const shutdown = async (signal) => {
  app.log.info(`received ${signal}, shutting down`);
  const timer = setTimeout(() => {
    app.log.error('graceful shutdown timed out, forcing exit');
    process.exit(1);
  }, SHUTDOWN_TIMEOUT_MS).unref();
  try {
    await app.close();
    clearTimeout(timer);
    process.exit(0);
  } catch (err) {
    app.log.error(err, 'error during shutdown');
    process.exit(1);
  }
};

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.once(signal, () => shutdown(signal));
}

try {
  await app.listen({ port: PORT, host: HOST });
  const b = getBuildInfo();
  app.log.info(`started ${b.app_name} version=${b.version} commit=${b.git_commit}`);
} catch (err) {
  app.log.error(err, 'failed to start');
  process.exit(1);
}
