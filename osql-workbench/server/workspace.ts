import { PGlite } from "@electric-sql/pglite";
import type {
  Assignments,
  Compilation,
  Generation,
  Inspection,
} from "../shared/types.js";
import { generateRows } from "./generate.js";

export const quote = (identifier: string) =>
  '"' + identifier.replaceAll('"', '""') + '"';
export type CompiledSelector = {
  setup: string;
  query: string;
  collection: boolean;
  type: string;
};
export type Compiler = <T>(
  endpoint: string,
  input: { source: string; root: string; query: string },
) => Promise<T>;

export class Workspace {
  source = "";
  root = "";
  model: Compilation | null = null;
  private db: PGlite | null = null;
  private tail: Promise<unknown> = Promise.resolve();
  constructor(private compiler: Compiler) {}

  // Every operation within a workspace is serialized, including recompilation.
  // A table read cannot observe a half-swapped schema or an active query setup.
  locked<T>(operation: () => Promise<T>): Promise<T> {
    const next = this.tail.then(operation);
    this.tail = next.catch(() => undefined);
    return next;
  }
  async compile(source: string, root: string): Promise<Compilation> {
    if (this.model && source === this.source && root === this.root)
      return this.model;
    const model = await this.compiler<Compilation>("compile", {
      source,
      root,
      query: "",
    });
    const previous = this.db;
    this.model = model;
    this.source = source;
    this.root = root;
    this.db = null;
    await previous?.close();
    return model;
  }
  async generate(count: number, assignments: Assignments): Promise<Generation> {
    if (!this.model) throw new Error("Compile an ontology first.");
    const rows = generateRows(this.model, count, assignments);
    const staged = new PGlite();
    try {
      await staged.exec("SET statement_timeout = '15s';");
      await staged.exec(this.model.sql);
      await staged.transaction(async (tx) => {
        for (const table of this.model!.tables) {
          const names = table.columns.map((c) => c.name);
          const insert = `INSERT INTO ${quote(table.name)} (${names.map(quote).join(",")}) OVERRIDING SYSTEM VALUE VALUES (${names.map((_, i) => "$" + (i + 1)).join(",")})`;
          for (const row of rows[table.name])
            await tx.query(
              insert,
              names.map((n) => row[n]),
            );
        }
        await tx.exec("SET CONSTRAINTS ALL IMMEDIATE;");
      });
    } catch (error) {
      await staged.close();
      throw error;
    }
    const previous = this.db;
    this.db = staged;
    await previous?.close();
    return {
      counts: Object.fromEntries(
        Object.entries(rows).map(([name, values]) => [name, values.length]),
      ),
    };
  }
  async inspect(name: string, offset: number): Promise<Inspection> {
    const table = this.model?.tables.find((t) => t.name === name);
    if (!table || !this.db)
      throw new Error("Generate data and select a compiled table first.");
    if (!Number.isInteger(offset) || offset < 0)
      throw new Error("Invalid table offset.");
    const total = await this.db.query<{ total: number }>(
      `SELECT count(*)::integer AS total FROM ${quote(name)}`,
    );
    const rows = await this.db.query(
      `SELECT * FROM ${quote(name)} ORDER BY ${table.primaryKey.map(quote).join(",")} LIMIT 100 OFFSET $1`,
      [offset],
    );
    return {
      table: name,
      total: total.rows[0].total,
      offset,
      rows: rows.rows as Record<string, unknown>[],
    };
  }
  async select(query: string): Promise<string> {
    if (!this.model || !this.db)
      throw new Error("Compile an ontology and generate data first.");
    if (!query.trim()) throw new Error("Write a selector first.");
    const compiled = await this.compiler<CompiledSelector>("query", {
      source: this.source,
      root: this.root,
      query,
    });
    await this.db.exec("BEGIN;");
    try {
      await this.db.exec(compiled.setup);
      // PostgreSQL renders each JSONB item to text. Avoid parsing through JS
      // numbers, which would silently round exact decimal query results.
      const source = compiled.query.trim().replace(/;$/, "");
      const sql = compiled.collection
        ? `SELECT item.value::text AS json FROM (${source}) AS result CROSS JOIN LATERAL jsonb_array_elements(result.value) AS item(value)`
        : `SELECT result.value::text AS json FROM (${source}) AS result`;
      const result = await this.db.query<{ json: string }>(sql);
      return result.rows.map((row) => row.json + "\n").join("");
    } finally {
      // Generated query functions are temporary to this run, including failures.
      await this.db.exec("ROLLBACK;");
    }
  }
  async close() {
    await this.tail;
    await this.db?.close();
  }
}
