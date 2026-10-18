export type Span = { start: number; end: number };
export type Atom = {
  kind: "string" | "number" | "boolean" | "timestamp" | "reference";
  values?: (string | number | boolean)[];
  target?: string;
};
export type Field = {
  id: string;
  population: string;
  path: string[];
  label: string;
  atom: Atom;
  source: Span | null;
};
export type Column = {
  name: string;
  type: string;
  nullable: boolean;
  generated: boolean;
  guards: string[];
  field: string | null;
  source: Span | null;
};
export type Reference = {
  fields: string[];
  target: string;
  targetFields: string[];
};
export type Table = {
  name: string;
  path: string[];
  population: string;
  source: Span | null;
  columns: Column[];
  primaryKey: string[];
  unique: string[][];
  references: Reference[];
  owner: Reference | null;
  branch: { field: string; value: string } | null;
  presence: string[];
};
export type Compilation = { tables: Table[]; fields: Field[]; sql: string };
export type Generator =
  | "auto"
  | "person.fullName"
  | "person.firstName"
  | "person.lastName"
  | "internet.email"
  | "internet.url"
  | "location.city"
  | "location.country"
  | "company.name"
  | "lorem.word"
  | "lorem.sentence"
  | "string.uuid"
  | "sequence"
  | "number.int"
  | "number.float"
  | "boolean"
  | "date.soon";
export type Assignments = Record<string, Generator>;
export type Inspection = {
  table: string;
  total: number;
  offset: number;
  rows: Record<string, unknown>[];
};
export type Generation = { counts: Record<string, number> };
export const generators: {
  value: Generator;
  label: string;
  kind: Atom["kind"] | "any";
}[] = [
  { value: "auto", label: "Automatic", kind: "any" },
  { value: "person.fullName", label: "Person · Full name", kind: "string" },
  { value: "person.firstName", label: "Person · First name", kind: "string" },
  { value: "person.lastName", label: "Person · Last name", kind: "string" },
  { value: "internet.email", label: "Internet · Email", kind: "string" },
  { value: "internet.url", label: "Internet · URL", kind: "string" },
  { value: "location.city", label: "Location · City", kind: "string" },
  { value: "location.country", label: "Location · Country", kind: "string" },
  { value: "company.name", label: "Company · Name", kind: "string" },
  { value: "lorem.word", label: "Text · Word", kind: "string" },
  { value: "lorem.sentence", label: "Text · Sentence", kind: "string" },
  { value: "string.uuid", label: "String · UUID", kind: "string" },
  { value: "sequence", label: "Number · Sequence", kind: "number" },
  { value: "number.int", label: "Number · Integer", kind: "number" },
  { value: "number.float", label: "Number · Decimal", kind: "number" },
  { value: "boolean", label: "Boolean", kind: "boolean" },
  { value: "date.soon", label: "Date · Upcoming", kind: "timestamp" },
];
