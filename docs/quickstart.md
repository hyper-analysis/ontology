# Ontology → tables → data → query

Run these commands from the repository root with `ontology` on your PATH.
After `make`, you can use `./build/ontology` instead. With Nix, replace
`ontology` with `nix run . --`.

## Check and compile

[school.ontology](../examples/school.ontology) describes people, courses and
course membership. `key email` and `key code` declare semantic identity;
references preserve identity, while a course's set of students is stored in
a dependent relation.

```sh
ontology check examples/school.ontology --root School
ontology inspect examples/school.ontology --root School
ontology compile examples/school.ontology --root School > schema.sql
```

The output is the [generated school schema](../examples/school.sql).

## Install and populate

Use an empty PostgreSQL 16 database. Set the standard PostgreSQL connection
variables as appropriate for your installation, then:

```sh
createdb ontology_demo
export PGDATABASE=ontology_demo
psql -X -v ON_ERROR_STOP=1 -f schema.sql
psql -X -v ON_ERROR_STOP=1 -f examples/school-data.sql
```

The seed inserts Alice and Bob, a MATH course taught by Alice, and Bob's
membership. The seed SQL targets this particular generated schema. Applications
should consume the compiler's storage metadata rather than guess physical names.

## Compile and execute O-SQL

```sh
ontology query examples/school.ontology examples/school.osql \
  --root School --namespace school_demo > query.sql
psql -X -qAt -v ON_ERROR_STOP=1 -f query.sql
```

The result is one JSONB value:

```json
[{"course":"MATH","teacher":"Alice","students":["Bob"]}]
```

Object-key formatting is PostgreSQL's choice; sets have no guaranteed transport
order. `query.sql` contains function definitions followed by the result query.
Install it under the same schema/search path as the ontology and data. Choose a
fresh `--namespace` for another installed query. Generated functions run with
the caller's privileges.

The `ontology query` command compiles O-SQL to PostgreSQL. It does not connect
to the database itself. The independent in-memory evaluator is future work.
