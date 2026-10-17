# Generated read-only ontology application

This is a generated local-development application, not an authenticated production deployment.

1. Install Node.js 22+ and PostgreSQL 16+.
2. Install `sql/schema.sql` into a fresh database/schema using a provisioning role. Never run that script over an existing schema.
3. Provision a separate SELECT-only runtime role. Do not use the schema owner's credentials in the server.
4. Run `npm install` and retain the resulting package-lock.json. Subsequent installs should use `npm ci`.
5. Run `npm run build`.
6. Export DATABASE_URL for the read-only role, then `npm start`. A `.env` file is not loaded implicitly; the `.env.example` file documents the variables.
7. Open `/views/<page>` with the identifying parameters in the URL query string. `views.txt` records names and semantic signatures. `/api/views/<page>` returns the technical JSON directly.

No page-to-page links, mutation actions, or runtime projection language are generated.
Components in `client/views` are pure prop renderers. Fetching is confined to `client/pages` and the shared transport wrapper. Raw JSON keys and enum values stay technical; visible captions and finite-value text are compiled from the label interpretation.

The `ir` directory records page-data, presentation, JSX, and endpoint descriptions. SQL, labels, and the existing label-checker IR were not reorganized to generate these files.

The plain presentation preserves nesting and shows explicit no-value, empty-array, and no-selected-fields states. Timestamps remain their technical string in this first printer. Arrays use positional React keys for stateless read-only snapshots, NOT ontology identities; stable identity-aware reconciliation is required before adding stateful item controls or edits.

The generated validators check response shapes and finite domains. Conditional branches are optional and mutually exclusive within their output object; they are guarded by property presence even when the discriminator was not selected. The type is a safe structural approximation, not a complete proof of every ontology invariant.

Server defaults to 127.0.0.1, uses parameterized queries inside read-only transactions with a five-second statement timeout, and returns no database error details to clients. This is not row-level authorization, pagination, or a general query-budget guarantee. Add the application's authentication/access policy before exposing it or using sensitive data.

