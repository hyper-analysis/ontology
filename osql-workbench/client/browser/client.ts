let worker: Worker | undefined;
let nextId = 0;
let runtimeLoaded = false;
let databaseLoaded = false;
const pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void; endpoint: string; timer: ReturnType<typeof setTimeout> }>();
function stop(message: string) {
  worker?.terminate(); worker = undefined; runtimeLoaded = false; databaseLoaded = false;
  for (const request of pending.values()) { clearTimeout(request.timer); request.reject(new Error(message)); }
  pending.clear();
}
function getWorker() {
  if (!worker) {
    worker = new Worker(new URL("./worker.ts", import.meta.url), { type: "module" });
    worker.onmessage = ({ data }) => {
      const request = pending.get(data.id);
      if (!request) return;
      pending.delete(data.id); clearTimeout(request.timer);
      if (data.error) request.reject(new Error(data.error));
      else {
        runtimeLoaded = true;
        if (request.endpoint === "/generate") databaseLoaded = true;
        if (request.endpoint === "/compile") databaseLoaded = false;
        request.resolve(data.value);
      }
    };
    worker.onerror = (event) => stop(`Browser runtime failed: ${event.message}. Compile and generate again to restore the workspace.`);
    worker.onmessageerror = () => stop("Browser runtime returned an unreadable message. Compile and generate again.");
  }
  return worker;
}
export function browserRequest<T>(endpoint: string, body?: unknown): Promise<T> {
  const runtime = getWorker();
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    // Initial engine/database downloads have a separate, longer request budget.
    const seconds = !runtimeLoaded || (endpoint === "/generate" && !databaseLoaded) ? 120 : 30;
    const timer = setTimeout(() => stop(`Browser execution exceeded ${seconds} seconds. The worker was reset; compile and generate again.`), seconds * 1000);
    pending.set(id, { resolve, reject, timer, endpoint });
    runtime.postMessage({ id, endpoint, body, assets: new URL(`${import.meta.env.BASE_URL}runtime/`, location.href).href });
  });
}
