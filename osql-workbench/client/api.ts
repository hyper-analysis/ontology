import { browserRequest } from "./browser/client";
export function request<T>(url: string, body?: unknown): Promise<T> { return browserRequest<T>(url, body); }
