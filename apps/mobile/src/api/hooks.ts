// Typed data-fetching hook over the shared JellyfinClient.
//
// Every query screen calls useJellyfin(fn, deps) instead of hand-rolling its
// own loading/error state - one place to get "don't setState after unmount"
// and "surface the error" right, rather than every screen re-deriving it.

import { useCallback, useEffect, useRef, useState } from 'react';
import type { DependencyList } from 'react';

export interface UseJellyfinResult<T> {
  data: T | null;
  loading: boolean;
  error: Error | null;
  /** Re-runs fn without needing a new deps array - retry-after-error, pull-to-refresh. */
  reload: () => void;
}

export function useJellyfin<T>(fn: () => Promise<T>, deps: DependencyList): UseJellyfinResult<T> {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);
  const [reloadToken, setReloadToken] = useState(0);

  // Ref so a fn identity change alone (a caller that didn't memoize) doesn't
  // skip a re-run - deps is the actual re-run trigger, same contract as useEffect.
  const fnRef = useRef(fn);
  fnRef.current = fn;

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);

    fnRef.current().then(
      result => {
        if (cancelled) return;
        setData(result);
        setLoading(false);
      },
      err => {
        if (cancelled) return;
        setError(err instanceof Error ? err : new Error(String(err)));
        setLoading(false);
      },
    );

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, reloadToken]);

  const reload = useCallback(() => setReloadToken(t => t + 1), []);

  return { data, loading, error, reload };
}
