import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { createClient } from "@supabase/supabase-js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const LOCAL_PROVIDER_STORE_PATH = path.resolve(__dirname, "../.sessions/provider-accounts.json");

const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? process.env.SUPABASE_ANON_KEY ?? "";

function ensureLocalProviderStore() {
  fs.mkdirSync(path.dirname(LOCAL_PROVIDER_STORE_PATH), { recursive: true });
  if (!fs.existsSync(LOCAL_PROVIDER_STORE_PATH)) {
    fs.writeFileSync(LOCAL_PROVIDER_STORE_PATH, JSON.stringify({ records: [] }, null, 2));
  }
}

function readLocalProviderStore() {
  try {
    ensureLocalProviderStore();
    return JSON.parse(fs.readFileSync(LOCAL_PROVIDER_STORE_PATH, "utf8"));
  } catch {
    return { records: [] };
  }
}

function isUUID(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value ?? ""));
}

function getSupabase(accessToken = null) {
  if (!SUPABASE_URL || !SUPABASE_KEY) return null;

  const options = accessToken
    ? {
        global: {
          headers: {
            Authorization: `Bearer ${accessToken}`,
          },
        },
      }
    : undefined;

  return createClient(SUPABASE_URL, SUPABASE_KEY, options);
}

function parseCookies(raw) {
  if (!raw) return [];
  if (Array.isArray(raw)) return raw;
  if (typeof raw !== "string") return [];

  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function normalizeAccountRecord(record) {
  if (!record) return null;
  const cookies = parseCookies(record.sessionCookies ?? record.session_cookies ?? record.cookies);
  if (!cookies.length) return null;

  return {
    userId: record.userId ?? record.user_id ?? null,
    provider: record.provider ?? null,
    providerEmail: record.providerEmail ?? record.provider_email ?? null,
    cookies,
    loginStatus: record.loginStatus ?? record.login_status ?? "logged_in",
    lastUsedAt: record.lastUsedAt ?? record.last_used_at ?? null,
    isActive: record.isActive ?? record.is_active ?? true,
  };
}

function listLocalProviderAccounts(userId = null, provider = null) {
  const store = readLocalProviderStore();
  return (store.records ?? [])
    .filter((record) => {
      if (userId && record.userId !== userId) return false;
      if (provider && record.provider !== provider) return false;
      return true;
    })
    .map(normalizeAccountRecord)
    .filter(Boolean);
}

function mostRecent(records) {
  return [...records].sort((a, b) => {
    const aTime = a.lastUsedAt ? Date.parse(a.lastUsedAt) : 0;
    const bTime = b.lastUsedAt ? Date.parse(b.lastUsedAt) : 0;
    return bTime - aTime;
  })[0] ?? null;
}

export async function loadProviderSession({ userId = null, provider, accessToken = null }) {
  const supabase = accessToken && isUUID(userId) ? getSupabase(accessToken) : null;
  if (supabase) {
    try {
      const { data } = await supabase
        .from("user_provider_accounts")
        .select("user_id, provider, provider_email, session_cookies, login_status, last_used_at, is_active")
        .eq("provider", provider)
        .eq("user_id", userId)
        .maybeSingle();

      const normalized = normalizeAccountRecord(data);
      if (normalized) {
        return { ...normalized, source: "supabase" };
      }
    } catch {}
  }

  const localRecords = listLocalProviderAccounts(userId, provider);
  const local = userId ? localRecords[0] : mostRecent(listLocalProviderAccounts(null, provider));
  if (local) {
    return { ...local, source: "local" };
  }

  return null;
}

export async function loadPreferredProviderSession(provider) {
  return await loadProviderSession({ provider });
}
