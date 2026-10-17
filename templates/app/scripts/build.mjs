import { build } from 'esbuild';
await build({
  entryPoints: ['client/main.tsx'], bundle: true, outfile: 'public/app.js',
  platform: 'browser', target: 'es2022', jsx: 'automatic',
  define: { 'process.env.NODE_ENV': JSON.stringify('production') }
});
await build({
  entryPoints: ['server/main.ts'], bundle: true, outfile: 'dist/server.mjs',
  platform: 'node', target: 'node22', format: 'esm', packages: 'external'
});

