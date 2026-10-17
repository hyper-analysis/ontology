import express, { type Express } from 'express';
import { Pool } from 'pg';
import { resolve } from 'node:path';

type Scalar = string | number | boolean;
type Parameter = { readonly name: string; readonly kind: 'string' | 'number' | 'boolean' | 'timestamp'; readonly allowed: readonly Scalar[] | null };
type Specification = { readonly name: string; readonly parameters: readonly Parameter[]; readonly sql: string };
type Installer = (app: Express, pool: Pool) => void;

class InvalidParameters extends Error {}

// One deterministic transport codec for the existing semantic signature.
export function bind(parameters: readonly Parameter[], input: unknown): Scalar[] {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) throw new InvalidParameters();
  const supplied = input as Record<string, unknown>;
  const expected = new Set(parameters.map(parameter => parameter.name));
  if (Object.keys(supplied).some(key => !expected.has(key))) throw new InvalidParameters();
  return parameters.map(parameter => {
    const raw = supplied[parameter.name];
    if (!Object.hasOwn(supplied, parameter.name) || typeof raw !== 'string' || raw.length > 4096) throw new InvalidParameters();
    let value: Scalar;
    switch (parameter.kind) {
      case 'string': value = raw; break;
      case 'number':
        if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(raw)) throw new InvalidParameters();
        value = Number(raw);
        if (!Number.isFinite(value)) throw new InvalidParameters();
        break;
      case 'boolean':
        if (raw !== 'true' && raw !== 'false') throw new InvalidParameters();
        value = raw === 'true';
        break;
      case 'timestamp':
        if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(raw) || !Number.isFinite(Date.parse(raw))) throw new InvalidParameters();
        value = raw;
        break;
    }
    if (parameter.allowed !== null && !parameter.allowed.some(candidate => candidate === value)) throw new InvalidParameters();
    return value;
  });
}

export function registerRead(app: Express, pool: Pool, specification: Specification, accept: (value: unknown) => boolean): void {
  app.get('/api/views/' + specification.name, async (request, response) => {
    let values: Scalar[];
    try { values = bind(specification.parameters, request.query); }
    catch { response.status(400).json({ error: 'invalid-parameters' }); return; }
    try {
      const client = await pool.connect();
      try {
        await client.query('BEGIN READ ONLY');
        await client.query("SET LOCAL statement_timeout = '5s'");
        const result = await client.query<{ value: unknown }>({ text: specification.sql, values });
        if (result.rows.length !== 1 || !result.rows[0] || !accept(result.rows[0].value)) throw new Error('View result contract violation');
        await client.query('COMMIT');
        response.json(result.rows[0].value);
      } catch (error) {
        await client.query('ROLLBACK').catch(() => undefined);
        throw error;
      } finally { client.release(); }
    } catch (error) {
      console.error('Generated read failed', error);
      response.status(500).json({ error: 'read-failed' });
    }
  });
}

// Loopback demo by default. Authentication and row-level authorization are not
// generated here. Use SELECT-only credentials and keep private data off this
// scaffold until the application's access policy has been integrated.
export function serve(installers: readonly Installer[], pages: readonly string[]): void {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) throw new Error('DATABASE_URL is required');
  const port = Number(process.env.PORT ?? '3000');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid PORT');
  const pool = new Pool({ connectionString, max: 5, connectionTimeoutMillis: 3000, idleTimeoutMillis: 30000 });
  pool.on('error', error => console.error('Database pool error', error));
  const app = express();
  app.disable('x-powered-by');
  app.set('query parser', 'simple');
  app.use((_request, response, next) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
    next();
  });
  for (const install of installers) install(app, pool);
  const publicDirectory = resolve(process.cwd(), 'public');
  for (const path of pages) app.get(path, (_request, response) => response.sendFile(resolve(publicDirectory, 'index.html')));
  app.use(express.static(publicDirectory));
  app.use((_request, response) => { response.status(404).json({ error: 'not-found' }); });
  const server = app.listen(port, process.env.HOST ?? '127.0.0.1', () => console.log('Listening on port ' + port));
  const stop = () => { server.close(() => { void pool.end(); }); };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
}

