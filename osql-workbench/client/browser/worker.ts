import { WASI, File, OpenFile, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
import { Workspace, type Compiler } from "../../server/workspace";

type Runtime = { workbench_run: (input: string) => Promise<string> };
let initialization: Promise<Runtime> | undefined;
let assets = "";
async function loadRuntime(): Promise<Runtime> {
  const response = await fetch(`${assets}workbench.wasm`);
  if (!response.ok) throw new Error("The browser runtime is missing. Build the WASM assets first.");
  const module = await WebAssembly.compile(await response.arrayBuffer());
  const { default: imports } = await import(/* @vite-ignore */ `${assets}workbench.js`);
  const exports: Record<string, unknown> = {};
  const wasi = new WASI([], [], [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((line) => console.log(line)),
    ConsoleStdout.lineBuffered((line) => console.warn(line)),
  ]);
  const instance = await WebAssembly.instantiate(module, {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: imports(exports),
  });
  Object.assign(exports, instance.exports);
  wasi.initialize(instance as Parameters<typeof wasi.initialize>[0]);
  return exports as Runtime;
}
async function execute<T>(input: unknown): Promise<T> {
  const runtime = await (initialization ??= loadRuntime());
  const result = JSON.parse(await runtime.workbench_run(JSON.stringify(input)));
  if (!result.ok) throw new Error(result.error);
  return result.value as T;
}
const compiler: Compiler = (operation, input) => execute({ operation, ...input });
const workspace = new Workspace(compiler);
let queue = Promise.resolve();
self.onmessage = (event: MessageEvent<{ id: number; endpoint: string; body?: any; assets: string }>) => {
  const { id, endpoint, body, assets: assetURL } = event.data;
  assets = assetURL;
  queue = queue.then(async () => {
    try {
      let value: unknown;
      if (endpoint === "/compile") value = await workspace.compile(body.source, body.root);
      else if (endpoint === "/generate") value = await workspace.generate(body.count, body.assignments ?? {});
      else if (endpoint === "/select") value = await workspace.select(body.query);
      else if (endpoint.startsWith("/tables/")) {
        const url = new URL(endpoint, "http://workspace.local");
        value = await workspace.inspect(decodeURIComponent(url.pathname.slice(8)), Number(url.searchParams.get("offset") ?? 0));
      } else throw new Error(`Unknown browser operation: ${endpoint}`);
      self.postMessage({ id, value });
    } catch (cause) {
      self.postMessage({ id, error: cause instanceof Error ? cause.message : String(cause) });
    }
  });
};
