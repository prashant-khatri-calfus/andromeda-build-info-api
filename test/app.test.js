import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { buildApp } from '../src/app.js';

const VARS = {
  APP_VERSION: '1.2.3',
  GIT_COMMIT: 'abc1234',
  GIT_BRANCH: 'main',
  BUILD_TIME: '2026-10-11T10:00:00Z',
  BUILD_ID: 'cb-42',
  POD_NAME: 'build-info-api-abc',
  ENVIRONMENT: 'test',
};
const ALL = [...Object.keys(VARS), 'FORCE_NOT_READY'];
let saved;
let app;

beforeEach(() => {
  saved = Object.fromEntries(ALL.map((k) => [k, process.env[k]]));
  Object.assign(process.env, VARS);
  delete process.env.FORCE_NOT_READY;
  app = buildApp({ logger: false });
});

afterEach(async () => {
  await app.close();
  for (const [k, v] of Object.entries(saved)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
});

test('GET /build-info returns injected build metadata', async () => {
  const res = await app.inject({ method: 'GET', url: '/build-info' });
  assert.equal(res.statusCode, 200);
  const body = res.json();
  assert.deepEqual(body.build, {
    app_name: 'build-info-api',
    version: '1.2.3',
    git_commit: 'abc1234',
    git_branch: 'main',
    build_time: '2026-10-11T10:00:00Z',
    build_id: 'cb-42',
  });
  assert.equal(body.runtime.pod_name, 'build-info-api-abc');
  assert.equal(body.runtime.environment, 'test');
  assert.ok(body.runtime.uptime_seconds >= 0);
  assert.match(body.timestamp, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
});

test('missing or blank metadata falls back to "unknown"', async () => {
  for (const k of ['GIT_BRANCH', 'BUILD_TIME', 'BUILD_ID']) delete process.env[k];
  process.env.GIT_COMMIT = '   ';
  const { build } = (await app.inject('/build-info')).json();
  assert.equal(build.git_commit, 'unknown');
  assert.equal(build.build_id, 'unknown');
});

test('health endpoints', async () => {
  assert.deepEqual((await app.inject('/healthz')).json(), { status: 'ok' });
  assert.equal((await app.inject('/readyz')).statusCode, 200);
});

test('readiness can be forced down', async () => {
  process.env.FORCE_NOT_READY = 'true';
  assert.equal((await app.inject('/readyz')).statusCode, 503);
});

test('unknown route returns 404', async () => {
  assert.equal((await app.inject('/nope')).statusCode, 404);
});
