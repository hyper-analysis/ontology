import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import type {
  Assignments,
  Compilation,
  Field,
  Generation,
  Generator,
  Inspection,
  Span,
  Table,
} from "../shared/types";
import { generators } from "../shared/types";
import { Editor } from "./Editor";
import { request } from "./api";
import { exampleOntology, exampleQuery } from "./example";
import "./style.css";

type Page = "ontology" | "data" | "selector";
function readSaved(key: string, fallback: string) {
  try {
    return localStorage.getItem(key) ?? fallback;
  } catch {
    return fallback;
  }
}
function save(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* Editing works even when storage is unavailable. */
  }
}
function download(name: string, data: string, type: string) {
  const url = URL.createObjectURL(new Blob([data], { type }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
function Icon({
  kind,
}: {
  kind: "file" | "play" | "table" | "arrow" | "download";
}) {
  const paths = {
    file: "M6 3h8l4 4v14H6z M14 3v5h4 M9 12h6 M9 16h6",
    play: "M8 4l12 8-12 8z",
    table: "M3 4h18v16H3z M3 9h18 M9 9v11",
    arrow: "M4 12h16 M14 6l6 6-6 6",
    download: "M12 3v12 M7 10l5 5 5-5 M4 17v4h16v-4",
  };
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={paths[kind]} />
    </svg>
  );
}
function Empty({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <div className="empty">
      <span className="empty-symbol">{`{ }`}</span>
      <h3>{title}</h3>
      <p>{children}</p>
    </div>
  );
}
function defaultGenerator(field: Field): Generator {
  if (field.atom.kind !== "string" || field.atom.values) return "auto";
  const name = field.path.at(-1)?.toLowerCase() ?? "";
  if (name.includes("email")) return "internet.email";
  if (name === "name") return "person.fullName";
  if (name === "city") return "location.city";
  if (name === "country") return "location.country";
  return "auto";
}
function TableBlocks({
  model,
  active,
  choose,
  links,
}: {
  model: Compilation;
  active: Span | null;
  choose: (span: Span | null) => void;
  links: boolean;
}) {
  const matches = (span: Span | null) =>
    !!(
      span &&
      active &&
      span.start === active.start &&
      span.end === active.end
    );
  return (
    <div className="table-blocks">
      {model.tables.map((table, index) => (
        <article
          className="table-block"
          key={table.name}
          id={"block-" + table.name}
        >
          <button
            className={"table-title " + (matches(table.source) ? "linked" : "")}
            onClick={() => choose(table.source)}
            disabled={!table.source}
            title="Locate type in ontology"
          >
            <span className="table-index">
              {String(index + 1).padStart(2, "0")}
            </span>
            <strong>{table.path.join(" → ")}</strong>
            <span className="type-tag">table</span>
          </button>
          <div className="physical-name">{table.name}</div>
          <div className="flattened-fields">
            {table.columns.map((column) => (
              <button
                key={column.name}
                className={
                  "flattened-field " + (matches(column.source) ? "linked" : "")
                }
                onClick={() => choose(column.source)}
                disabled={!column.source}
                title={
                  column.source
                    ? "Locate field in ontology"
                    : "Compiler-generated storage field"
                }
              >
                <span
                  className={
                    "column-mark " +
                    (table.primaryKey.includes(column.name) ? "key" : "")
                  }
                >
                  {table.primaryKey.includes(column.name) ? "⌑" : "·"}
                </span>
                <code>
                  {column.name}
                  {column.nullable ? "?" : ""}
                </code>
                <span className="column-type">{column.type}</span>
                {column.source && <span className="source-link">↗</span>}
              </button>
            ))}
          </div>
          {links && table.references.length > 0 && (
            <div className="table-relations">
              {table.references.map((ref, i) => (
                <a
                  href={"#block-" + ref.target}
                  key={i}
                  onClick={(event) => {
                    event.preventDefault();
                    document
                      .getElementById("block-" + ref.target)
                      ?.scrollIntoView({ behavior: "smooth", block: "center" });
                  }}
                >
                  <span>{ref.fields.join(", ")}</span>
                  <Icon kind="arrow" />
                  <span>
                    {model.tables
                      .find((t) => t.name === ref.target)
                      ?.path.join(".") ?? ref.target}
                  </span>
                </a>
              ))}
            </div>
          )}
        </article>
      ))}
    </div>
  );
}
function GeneratorFields({
  model,
  assignments,
  onChange,
}: {
  model: Compilation;
  assignments: Assignments;
  onChange: (id: string, value: Generator) => void;
}) {
  const populations = [...new Set(model.fields.map((f) => f.population))];
  return (
    <div className="generator-groups">
      {populations.map((population) => (
        <section className="generator-group" key={population}>
          <div className="group-heading">
            <span className="dot" />
            <h3>{population}</h3>
            <span>
              {model.fields.filter((f) => f.population === population).length}{" "}
              fields
            </span>
          </div>
          {model.fields
            .filter((f) => f.population === population)
            .map((field) => {
              const constrained =
                field.atom.kind === "reference" || !!field.atom.values;
              return (
                <div className="generator-field" key={field.id}>
                  <div>
                    <code>{field.label}</code>
                    <small>
                      {field.atom.target
                        ? `Ref<${field.atom.target}>`
                        : field.atom.values
                          ? field.atom.values.map(String).join(" | ")
                          : field.atom.kind}
                    </small>
                  </div>
                  <select
                    aria-label={
                      "Generator for " + field.population + "." + field.label
                    }
                    value={assignments[field.id] ?? "auto"}
                    onChange={(e) =>
                      onChange(field.id, e.target.value as Generator)
                    }
                    disabled={constrained}
                  >
                    {generators
                      .filter(
                        (g) => g.kind === "any" || g.kind === field.atom.kind,
                      )
                      .map((g) => (
                        <option key={g.value} value={g.value}>
                          {constrained
                            ? field.atom.target
                              ? "Linked population"
                              : "Ontology values"
                            : g.label}
                        </option>
                      ))}
                  </select>
                </div>
              );
            })}
        </section>
      ))}
    </div>
  );
}
function formatCell(value: unknown) {
  if (value === null) return <span className="null">null</span>;
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}
function TableInspector({
  model,
  generation,
}: {
  model: Compilation;
  generation: Generation;
}) {
  const [selected, setSelected] = useState(model.tables[0]?.name ?? "");
  const [inspection, setInspection] = useState<Inspection | null>(null);
  const [offset, setOffset] = useState(0);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError("");
    setInspection(null);
    request<Inspection>(
      `/tables/${encodeURIComponent(selected)}?offset=${offset}`,
    )
      .then((data) => {
        if (!cancelled) setInspection(data);
      })
      .catch((e) => {
        if (!cancelled) setError(e.message);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [selected, offset, generation]);
  const table = model.tables.find((t) => t.name === selected);
  return (
    <div className="inspector">
      <aside className="table-sidebar">
        <div className="sidebar-caption">
          TABLES <span>{model.tables.length}</span>
        </div>
        {model.tables.map((table) => (
          <button
            className={selected === table.name ? "selected" : ""}
            onClick={() => {
              setSelected(table.name);
              setOffset(0);
            }}
            key={table.name}
          >
            <Icon kind="table" />
            <span>{table.path.join(".")}</span>
            <small>{generation.counts[table.name] ?? 0}</small>
          </button>
        ))}
      </aside>
      <section className="table-content">
        <div className="table-content-heading">
          <div>
            <h2>{table?.path.join(".")}</h2>
            <code>{selected}</code>
          </div>
          <span className="quiet">
            {inspection?.total ?? generation.counts[selected] ?? 0} rows
          </span>
        </div>
        {error && (
          <pre className="inline-error" role="alert">
            {error}
          </pre>
        )}
        {loading ? (
          <p className="loading">Loading table…</p>
        ) : (
          inspection && (
            <>
              <div className="grid-scroll">
                <table>
                  <thead>
                    <tr>
                      {table?.columns.map((column) => (
                        <th key={column.name}>
                          {column.name}
                          <small>{column.type}</small>
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {inspection.rows.map((row, index) => (
                      <tr key={index}>
                        {table?.columns.map((column) => (
                          <td key={column.name}>
                            {formatCell(row[column.name])}
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
                {inspection.rows.length === 0 && (
                  <p className="no-rows">This table has no rows.</p>
                )}
              </div>
              <div className="pagination">
                <span>
                  {inspection.total === 0
                    ? "0 rows"
                    : `${offset + 1}–${offset + inspection.rows.length} of ${inspection.total}`}
                </span>
                <button
                  onClick={() => setOffset(Math.max(0, offset - 100))}
                  disabled={offset === 0}
                >
                  Previous
                </button>
                <button
                  onClick={() => setOffset(offset + 100)}
                  disabled={offset + inspection.rows.length >= inspection.total}
                >
                  Next
                </button>
              </div>
            </>
          )
        )}
      </section>
    </div>
  );
}
function App() {
  const [page, setPage] = useState<Page>("ontology");
  const [source, setSource] = useState(() =>
    readSaved("osql.source", exampleOntology),
  );
  const [root, setRoot] = useState(() => readSaved("osql.root", "Root"));
  const [query, setQuery] = useState(() =>
    readSaved("osql.query", exampleQuery),
  );
  const queryRef = useRef(query);
  queryRef.current = query;
  const [compiledSource, setCompiledSource] = useState("");
  const [compiledRoot, setCompiledRoot] = useState("");
  const [model, setModel] = useState<Compilation | null>(null);
  const [selection, setSelection] = useState<Span | null>(null);
  const [activeSpan, setActiveSpan] = useState<Span | null>(null);
  const [links, setLinks] = useState(true);
  const [assignments, setAssignments] = useState<Assignments>({});
  const [count, setCount] = useState("25");
  const [generation, setGeneration] = useState<Generation | null>(null);
  const [tab, setTab] = useState<"generate" | "inspect">("generate");
  const [busy, setBusy] = useState<"compile" | "generate" | "run" | null>(null);
  const [errors, setErrors] = useState<Partial<Record<Page, string>>>({});
  const [output, setOutput] = useState<string | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [copied, setCopied] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);
  const dirty = source !== compiledSource || root !== compiledRoot;
  const ready = !!model && !dirty;
  useEffect(() => {
    save("osql.source", source);
  }, [source]);
  useEffect(() => {
    save("osql.root", root);
  }, [root]);
  useEffect(() => {
    save("osql.query", query);
  }, [query]);
  async function compile() {
    if (busy) return;
    setBusy("compile");
    setErrors((previous) => ({ ...previous, ontology: "" }));
    try {
      const value = await request<Compilation>("/compile", { source, root });
      const changed = source !== compiledSource || root !== compiledRoot;
      setModel(value);
      setCompiledSource(source);
      setCompiledRoot(root);
      setSelection(null);
      setActiveSpan(null);
      setAssignments((previous) =>
        Object.fromEntries(
          value.fields.map((field) => [
            field.id,
            previous[field.id] ?? defaultGenerator(field),
          ]),
        ),
      );
      if (changed) {
        setGeneration(null);
        setOutput(null);
        setTab("generate");
      }
    } catch (e) {
      setErrors((previous) => ({
        ...previous,
        ontology: (e as Error).message,
      }));
    } finally {
      setBusy(null);
    }
  }
  async function generate() {
    if (!ready || busy) return;
    setBusy("generate");
    setErrors((previous) => ({ ...previous, data: "" }));
    try {
      setGeneration(
        await request<Generation>("/generate", {
          count: Number(count),
          assignments,
        }),
      );
      setOutput(null);
      setTab("inspect");
    } catch (e) {
      setErrors((previous) => ({ ...previous, data: (e as Error).message }));
    } finally {
      setBusy(null);
    }
  }
  async function run() {
    if (!ready || !generation || busy) return;
    setBusy("run");
    setErrors((previous) => ({ ...previous, selector: "" }));
    setOutput(null);
    const start = performance.now();
    try {
      const result = await request<string>("/select", { query });
      if (queryRef.current === query) {
        setOutput(result);
        setElapsed(Math.round(performance.now() - start));
      }
    } catch (e) {
      setErrors((previous) => ({
        ...previous,
        selector: (e as Error).message,
      }));
    } finally {
      setBusy(null);
    }
  }
  function cursor(offset: number) {
    if (!ready) return;
    const span = model?.fields
      .map((f) => f.source)
      .find((s) => s && offset >= s.start && offset <= s.end);
    setActiveSpan(span ?? null);
  }
  return (
    <div className="app-shell">
      <header className="app-header">
        <a
          className="brand"
          href="#ontology"
          onClick={(e) => {
            e.preventDefault();
            setPage("ontology");
          }}
        >
          <span className="brand-symbol">
            o<span>:</span>
          </span>
          <strong>OSQL</strong>
          <span className="brand-divider" />
          <span className="brand-subtitle">Workbench</span>
        </a>
        <nav aria-label="Pages">
          {(["ontology", "data", "selector"] as Page[]).map((name, i) => (
            <button
              aria-current={page === name ? "page" : undefined}
              className={page === name ? "active" : ""}
              onClick={() => setPage(name)}
              key={name}
            >
              <span>{String(i + 1).padStart(2, "0")}</span>
              {name[0].toUpperCase() + name.slice(1)}
            </button>
          ))}
        </nav>
        <span className="project-status">
          <i className={ready ? "ready" : ""} />
          {ready ? "Compiled" : model ? "Uncompiled changes" : "Not compiled"}
        </span>
      </header>
      <main>
        <div className="page-heading">
          <div>
            <div className="eyebrow">
              {page === "ontology"
                ? "DEFINE YOUR WORLD"
                : page === "data"
                  ? "GIVE IT DATA"
                  : "ASK A QUESTION"}
            </div>
            <h1>
              {page === "ontology"
                ? "Ontology"
                : page === "data"
                  ? "Data"
                  : "Selector"}
            </h1>
          </div>
          <p>
            {page === "ontology"
              ? "Write the types. See the tables."
              : page === "data"
                ? "Choose the values. Inspect the population."
                : "Write a selector. Get your data."}
          </p>
        </div>
        {(page === "data" || page === "selector") && !ready && (
          <div className="notice">
            {model
              ? "The ontology has changed. Compile it before continuing."
              : "Compile your ontology to begin."}
            <button onClick={() => setPage("ontology")}>
              Open ontology <Icon kind="arrow" />
            </button>
          </div>
        )}
        {errors[page] && (
          <div className="error-banner" role="alert">
            <pre>{errors[page]}</pre>
            <button
              aria-label="Dismiss error"
              onClick={() =>
                setErrors((previous) => ({ ...previous, [page]: "" }))
              }
            >
              ×
            </button>
          </div>
        )}
        {page === "ontology" && (
          <section className="ontology-layout">
            <div className="source-pane panel">
              <div className="pane-toolbar">
                <span className="file-name">
                  <Icon kind="file" />
                  ontology.ontology
                </span>
                <div className="toolbar-actions">
                  <button
                    className="text-button"
                    disabled={!!busy}
                    onClick={() => fileInput.current?.click()}
                  >
                    Open
                  </button>
                  <button
                    className="icon-button"
                    aria-label="Download ontology"
                    onClick={() =>
                      download("ontology.ontology", source, "text/plain")
                    }
                  >
                    <Icon kind="download" />
                  </button>
                </div>
              </div>
              <div className="source-editor">
                <Editor
                  value={source}
                  onChange={setSource}
                  onCursor={cursor}
                  selection={selection}
                  onRun={compile}
                  label="Ontology source"
                />
              </div>
              <div className="source-footer">
                <label>
                  Root type{" "}
                  <input
                    aria-label="Root type"
                    value={root}
                    onChange={(e) => setRoot(e.target.value)}
                    disabled={!!busy}
                  />
                </label>
                <button
                  className="primary"
                  onClick={compile}
                  disabled={!!busy || !source.trim() || !root.trim()}
                >
                  <Icon kind="play" />
                  {busy === "compile" ? "Compiling…" : "Compile"}
                </button>
              </div>
              <input
                ref={fileInput}
                type="file"
                accept=".ontology,.txt,.ts"
                hidden
                onChange={async (e) => {
                  const file = e.target.files?.[0];
                  if (file) setSource(await file.text());
                  e.target.value = "";
                }}
              />
            </div>
            <div className="compiled-pane panel">
              <div className="pane-toolbar">
                <span className="pane-label">
                  Flattened ontology{" "}
                  {model && (
                    <span className="count-badge">
                      {model.tables.length} tables
                    </span>
                  )}
                </span>
                <label className="checkbox-label">
                  <input
                    type="checkbox"
                    checked={links}
                    onChange={(e) => setLinks(e.target.checked)}
                  />
                  Relations
                </label>
              </div>
              <div
                className={"compiled-scroll " + (dirty && model ? "stale" : "")}
              >
                {model ? (
                  <TableBlocks
                    model={model}
                    active={activeSpan}
                    choose={(span) => {
                      if (ready) {
                        setActiveSpan(span);
                        setSelection(span ? { ...span } : null);
                      }
                    }}
                    links={links}
                  />
                ) : (
                  <Empty title="Your tables appear here">
                    Compile the ontology to see its flattened structure.
                  </Empty>
                )}
              </div>
              <div className="pane-footnote">
                {dirty && model
                  ? "Previous compilation · compile to update"
                  : "Select a field to locate its source token."}
              </div>
            </div>
          </section>
        )}
        {page === "data" && (
          <section className="panel data-panel">
            <div className="data-toolbar">
              <div className="tabs" role="tablist" aria-label="Data views">
                <button
                  role="tab"
                  aria-selected={tab === "generate"}
                  onClick={() => setTab("generate")}
                >
                  Generation
                </button>
                <button
                  role="tab"
                  aria-selected={tab === "inspect"}
                  onClick={() => setTab("inspect")}
                  disabled={!generation}
                >
                  Tables
                  {generation && (
                    <span className="count-badge">
                      {Object.keys(generation.counts).length}
                    </span>
                  )}
                </button>
              </div>
              {tab === "generate" && (
                <div className="generation-controls">
                  <label>
                    N{" "}
                    <input
                      aria-label="Number of records"
                      type="number"
                      min="0"
                      max="1000"
                      step="1"
                      disabled={!!busy}
                      value={count}
                      onChange={(e) => setCount(e.target.value)}
                    />
                  </label>
                  <button
                    className="primary"
                    disabled={
                      !ready ||
                      !!busy ||
                      count === "" ||
                      !Number.isInteger(Number(count)) ||
                      Number(count) < 0 ||
                      Number(count) > 1000
                    }
                    onClick={generate}
                  >
                    {busy === "generate" ? "Generating…" : "Generate " + count}
                    <Icon kind="arrow" />
                  </button>
                </div>
              )}
            </div>
            {tab === "generate" ? (
              model ? (
                <>
                  <div className="generation-intro">
                    <h2>Field generators</h2>
                    <p>
                      N records per population. References and table
                      relationships follow the ontology.
                    </p>
                  </div>
                  <fieldset
                    disabled={!ready || !!busy}
                    className="generator-fieldset"
                  >
                    <GeneratorFields
                      model={model}
                      assignments={assignments}
                      onChange={(id, value) =>
                        setAssignments((previous) => ({
                          ...previous,
                          [id]: value,
                        }))
                      }
                    />
                  </fieldset>
                </>
              ) : (
                <Empty title="Start with an ontology">
                  Its fields will appear here after compilation.
                </Empty>
              )
            ) : (
              model &&
              generation && (
                <TableInspector
                  key={compiledSource}
                  model={model}
                  generation={generation}
                />
              )
            )}
          </section>
        )}
        {page === "selector" && (
          <section className="panel selector-panel">
            <div className="pane-toolbar">
              <span className="file-name">
                <Icon kind="file" />
                selector.osql
              </span>
              <div className="toolbar-actions">
                <span className="shortcut">⌘ / Ctrl ↵</span>
                <button
                  className="primary"
                  onClick={run}
                  disabled={!ready || !generation || !!busy || !query.trim()}
                >
                  <Icon kind="play" />
                  {busy === "run" ? "Running…" : "Run"}
                </button>
              </div>
            </div>
            <div className="query-editor">
              <Editor
                value={query}
                onChange={(value) => {
                  setQuery(value);
                  setOutput(null);
                }}
                onRun={run}
                label="OSQL selector"
              />
            </div>
            <div className="results-heading">
              <span>
                RESULT <span className="format-badge">NDJSON</span>
              </span>
              <div>
                {output !== null && (
                  <>
                    <span className="quiet">
                      {output.trim() ? output.trim().split("\n").length : 0}{" "}
                      lines · {elapsed} ms
                    </span>
                    <button
                      className="text-button"
                      onClick={async () => {
                        try {
                          await navigator.clipboard.writeText(output);
                          setCopied(true);
                          setTimeout(() => setCopied(false), 1800);
                        } catch {
                          setErrors((previous) => ({
                            ...previous,
                            selector:
                              "Clipboard unavailable. Use Download to save the result.",
                          }));
                        }
                      }}
                    >
                      {copied ? "Copied" : "Copy"}
                    </button>
                    <button
                      className="icon-button"
                      aria-label="Download NDJSON"
                      onClick={() =>
                        download(
                          "result.ndjson",
                          output,
                          "application/x-ndjson",
                        )
                      }
                    >
                      <Icon kind="download" />
                    </button>
                  </>
                )}
              </div>
            </div>
            {output === null ? (
              <Empty
                title={
                  busy === "run"
                    ? "Running selector…"
                    : !generation
                      ? "Generate a population first"
                      : "Ready when you are"
                }
              >
                {!generation
                  ? "The selector runs against your generated data."
                  : "Run your selector to receive newline-delimited JSON."}
              </Empty>
            ) : output === "" ? (
              <div className="empty-result">0 results</div>
            ) : (
              <pre className="ndjson" aria-label="NDJSON result">
                {output}
              </pre>
            )}
          </section>
        )}
      </main>
      <footer className="app-footer">
        <span>
          OSQL <span className="footer-dot">·</span> {import.meta.env.VITE_RUNTIME === "browser" ? "Runs locally in your browser" : "Ontology → tables → data"}
        </span>
        <span>
          {page === "ontology"
            ? "01 / 03"
            : page === "data"
              ? "02 / 03"
              : "03 / 03"}
        </span>
      </footer>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
