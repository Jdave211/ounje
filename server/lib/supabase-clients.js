// Single source of truth for Supabase JS clients used inside the API process.
//
// Previously each route file called `createClient(...)` either inside the
// request handler or via an un-memoized factory, so every request paid the
// cost of building a new HTTP client + losing keep-alive reuse. Under load,
// that contributes meaningfully to perceived latency and to the "too many
// requests" pressure the user is seeing.
//
// All backend modules should `import { getServiceRoleSupabase } from
// "../lib/supabase-clients.js"` instead of constructing their own clients.
//
// We intentionally keep the clients lazy + module-scoped (not eager) so the
// process can boot without Supabase env vars (e.g. during a partial deploy)
// and so we don't pay the cost in scripts that don't actually need them.

import { createClient } from "@supabase/supabase-js";

let serviceRoleClient = null;
let anonClient = null;

export const DEFAULT_SUPABASE_FETCH_TIMEOUT_MS = Math.max(
  1_000,
  Number.parseInt(String(process.env.SUPABASE_FETCH_TIMEOUT_MS ?? ""), 10) || 12_000
);

function readEnv(name) {
  return String(process.env[name] ?? "").trim();
}

function timeoutFetch(timeoutMs = DEFAULT_SUPABASE_FETCH_TIMEOUT_MS) {
  return async function fetchWithSupabaseTimeout(input, init = {}) {
    const controller = new AbortController();
    const upstreamSignal = init.signal;
    const timeoutID = setTimeout(() => {
      controller.abort(new Error(`supabase_fetch_timeout_${timeoutMs}ms`));
    }, timeoutMs);

    const abortFromUpstream = () => {
      controller.abort(upstreamSignal?.reason ?? new Error("supabase_fetch_aborted"));
    };

    if (upstreamSignal?.aborted) {
      abortFromUpstream();
    } else if (upstreamSignal) {
      upstreamSignal.addEventListener("abort", abortFromUpstream, { once: true });
    }

    try {
      return await fetch(input, {
        ...init,
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timeoutID);
      upstreamSignal?.removeEventListener?.("abort", abortFromUpstream);
    }
  };
}

export function defaultClientOptions({ timeoutMs = DEFAULT_SUPABASE_FETCH_TIMEOUT_MS } = {}) {
  return {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
    global: {
      fetch: timeoutFetch(timeoutMs),
    },
  };
}

/**
 * Returns a lazily-constructed module-singleton Supabase client backed by the
 * service-role key. Throws if SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY is
 * missing so callers fail loudly instead of silently using a broken client.
 */
export function getServiceRoleSupabase() {
  if (serviceRoleClient) return serviceRoleClient;

  const url = readEnv("SUPABASE_URL");
  const key = readEnv("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new Error("Supabase service-role configuration is missing (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY)");
  }

  serviceRoleClient = createClient(url, key, defaultClientOptions());
  return serviceRoleClient;
}

/**
 * Returns a lazily-constructed module-singleton Supabase client backed by the
 * anon key. Use only for paths that intentionally want RLS-enforced reads
 * (rare on the backend; usually you want service-role).
 */
export function getAnonSupabase() {
  if (anonClient) return anonClient;

  const url = readEnv("SUPABASE_URL");
  const key = readEnv("SUPABASE_ANON_KEY");
  if (!url || !key) {
    throw new Error("Supabase anon configuration is missing (SUPABASE_URL / SUPABASE_ANON_KEY)");
  }

  anonClient = createClient(url, key, defaultClientOptions());
  return anonClient;
}

/**
 * Test/dev-only escape hatch: forget the cached singletons. Real production
 * code paths should never call this.
 */
export function _resetSupabaseClientsForTest() {
  serviceRoleClient = null;
  anonClient = null;
}
