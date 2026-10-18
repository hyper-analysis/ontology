import { Faker, en } from "@faker-js/faker";
import type {
  Assignments,
  Compilation,
  Field,
  Generator,
  Table,
} from "../shared/types.js";
import { generators } from "../shared/types.js";

type Row = Record<string, unknown>;
export type Population = Record<string, Row[]>;

export function validateAssignments(
  model: Compilation,
  assignments: Assignments,
) {
  for (const [id, generator] of Object.entries(assignments)) {
    const field = model.fields.find((f) => f.id === id);
    const option = generators.find((g) => g.value === generator);
    if (
      !field ||
      !option ||
      (option.kind !== "any" && option.kind !== field.atom.kind)
    ) {
      throw new Error(`Invalid generator assignment: ${id}`);
    }
    if (
      (field.atom.kind === "reference" || field.atom.values) &&
      generator !== "auto"
    ) {
      throw new Error(
        `${field.label} is constrained by the ontology and uses Automatic.`,
      );
    }
  }
}

function fakeValue(
  faker: Faker,
  field: Field | undefined,
  generator: Generator,
  index: number,
  type: string,
): unknown {
  const values = field?.atom.values;
  if (values) return values[index % values.length];
  switch (generator) {
    case "person.fullName":
      return faker.person.fullName();
    case "person.firstName":
      return faker.person.firstName();
    case "person.lastName":
      return faker.person.lastName();
    case "internet.email":
      return faker.internet.email();
    case "internet.url":
      return faker.internet.url();
    case "location.city":
      return faker.location.city();
    case "location.country":
      return faker.location.country();
    case "company.name":
      return faker.company.name();
    case "lorem.word":
      return faker.lorem.word();
    case "lorem.sentence":
      return faker.lorem.sentence();
    case "string.uuid":
      return faker.string.uuid();
    case "sequence":
      return index + 1;
    case "number.int":
      return faker.number.int({ min: 0, max: 1000000 });
    case "number.float":
      return faker.number.float({ min: 0, max: 10000, fractionDigits: 2 });
    case "boolean":
      return faker.datatype.boolean();
    case "date.soon":
      return faker.date
        .soon({ days: 365, refDate: "2026-01-01T00:00:00Z" })
        .toISOString();
    case "auto":
      if (type === "numeric" || type === "bigint") return index + 1;
      if (type === "boolean") return index % 2 === 0;
      if (type === "timestamptz")
        return faker.date
          .soon({ days: 365, refDate: "2026-01-01T00:00:00Z" })
          .toISOString();
      return faker.string.uuid();
  }
}

// Reserve population IDs before filling fields: forward and cyclic references
// can target actual rows even when their values haven't been generated yet.
export function generateRows(
  model: Compilation,
  count: number,
  assignments: Assignments,
  seed = 42,
): Population {
  if (!Number.isInteger(count) || count < 0 || count > 1000)
    throw new Error("N must be an integer between 0 and 1000.");
  validateAssignments(model, assignments);
  const faker = new Faker({ locale: [en] });
  faker.seed(seed);
  const fields = new Map(model.fields.map((f) => [f.id, f]));
  const result: Population = Object.fromEntries(
    model.tables.map((t) => [t.name, []]),
  );
  for (const table of model.tables.filter((t) => !t.owner)) {
    result[table.name] = Array.from({ length: count }, (_, i) => ({
      id: i + 1,
    }));
  }
  const populated = new Set<string>();
  const fill = (table: Table) => {
    if (populated.has(table.name)) return;
    if (table.owner) {
      const owner = model.tables.find((t) => t.name === table.owner!.target);
      if (!owner) throw new Error(`Missing owner table for ${table.name}`);
      fill(owner);
      result[table.name] = result[owner.name]
        .filter(
          (parent) =>
            (!table.branch ||
              parent[table.branch.field] === table.branch.value) &&
            table.presence.every((p) => parent[p] === true),
        )
        .map((parent) =>
          Object.fromEntries(
            table.owner!.fields.map((name, i) => [
              name,
              parent[table.owner!.targetFields[i]],
            ]),
          ),
        );
    }
    const uniqueKeys = [table.primaryKey, ...table.unique];
    const seen = uniqueKeys.map(() => new Set<string>());
    result[table.name].forEach((row, index) => {
      const inherited = new Set(Object.keys(row));
      let accepted = false;
      for (let attempt = 0; attempt < 100; attempt++) {
        const ordinal = index + attempt * Math.max(count, 1);
        for (const column of table.columns) {
          if (inherited.has(column.name)) continue;
          if (!column.field && column.type === "boolean") {
            row[column.name] = true;
            continue;
          }
          const field = column.field ? fields.get(column.field) : undefined;
          row[column.name] = fakeValue(
            faker,
            field,
            assignments[column.field ?? ""] ?? "auto",
            ordinal,
            column.type,
          );
        }
        for (const reference of table.references) {
          if (reference.fields.every((f) => inherited.has(f))) continue;
          const targets = result[reference.target];
          if (!targets?.length)
            throw new Error(
              `No target rows for reference ${table.name} → ${reference.target}`,
            );
          const target = targets[ordinal % targets.length];
          reference.fields.forEach((name, i) => {
            if (!inherited.has(name))
              row[name] = target[reference.targetFields[i]];
          });
        }
        for (const column of table.columns) {
          if (column.guards.some((g) => row[g] !== true))
            row[column.name] = null;
        }
        const keys = uniqueKeys.map((names) =>
          JSON.stringify(names.map((n) => row[n])),
        );
        if (keys.every((key, i) => !seen[i].has(key))) {
          keys.forEach((key, i) => seen[i].add(key));
          accepted = true;
          break;
        }
      }
      if (!accepted)
        throw new Error(
          `Cannot generate ${count} distinct rows for ${table.path.join(".")}. Choose a larger Faker value space or reduce N.`,
        );
    });
    populated.add(table.name);
  };
  model.tables.forEach(fill);
  return result;
}
