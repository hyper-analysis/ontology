# Experimental application compilation

This branch preserves the application compiler as a separate research direction.
The released `ontology` CLI stays focused on the model, PostgreSQL and O-SQL.

The prototype consumes an ontology, optional checked labels and explicit page
specifications. It generates a read-only React/Express application, technical
response validators, parameterized SQL reads and intermediate descriptions.
It does not infer a complete application from the domain model alone.

## Run the prototype

From the repository root, with the core development dependencies plus aeson,
bytestring, text and vector:

```sh
make app
./build/ontology-app test/fixtures/labels.ontology Root \
  test/fixtures/labels.en.label examples/labels.app.json /tmp/ontology-demo
cd /tmp/ontology-demo
npm install
npm run build
```

Choose a new output directory: the compiler refuses to overwrite an existing one.
The generated README describes database provisioning and local execution.
Cabal users can build `cabal build -fexperimental-app exe:ontology-app`.
The experimental Cabal flag is off by default.

## Boundaries

- Page choices and labels are explicit inputs, not inferred UX policy.
- Only read-only views and endpoints are generated.
- The runtime template has no authentication or application authorization.
- The generated app requires Node.js and PostgreSQL; it is a development scaffold.
- The core release has no dependency on this branch.

The branch imports the prepared-view, centering and label infrastructure needed
by the prototype. See [application equations](application-equations.md),
[label equations](label-equations.md), [read equations](read-equations.md),
and [projection policy](projectors.md).

