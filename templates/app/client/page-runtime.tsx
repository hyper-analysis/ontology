import { useEffect, useState, type ComponentType } from 'react';

type State<T> = { status: 'loading' } | { status: 'failed'; message: string } | { status: 'ready'; data: T };

// Transport only. The specialized View owns no request, routing, or state logic.
export function ReadPage<T>({ endpoint, accept, View }: {
  endpoint: string;
  accept: (value: unknown) => value is T;
  View: ComponentType<{ readonly data: T }>;
}) {
  const search = window.location.search;
  const [state, setState] = useState<State<T>>({ status: 'loading' });
  useEffect(() => {
    const controller = new AbortController();
    setState({ status: 'loading' });
    void (async () => {
      try {
        const response = await fetch(endpoint + search, { signal: controller.signal, cache: 'no-store' });
        if (!response.ok) throw new Error(response.status === 400 ? 'Invalid view parameters' : 'Read request failed');
        const value: unknown = await response.json();
        if (!accept(value)) throw new Error('Response does not match this view');
        if (!controller.signal.aborted) setState({ status: 'ready', data: value });
      } catch (error) {
        if (!controller.signal.aborted) setState({ status: 'failed', message: error instanceof Error ? error.message : 'Read request failed' });
      }
    })();
    return () => controller.abort();
  }, [endpoint, accept, search]);
  if (state.status === 'loading') return <main><p role="status">Loading</p></main>;
  if (state.status === 'failed') return <main><p role="alert">{state.message}</p></main>;
  return <View data={state.data} />;
}

