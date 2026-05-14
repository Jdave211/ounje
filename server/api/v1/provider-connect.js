/**
 * Provider Connection API
 * 
 * Allows users to connect their grocery provider accounts (Instacart, Walmart, etc.)
 * by logging in through a server-controlled browser session.
 * 
 * Flow:
 *   1. POST /connect/:provider      → Start connection session
 *   2. User opens connectUrl        → Logs in via browser proxy
 *   3. GET /connect/:provider/status → Check if connected
 *   4. DELETE /connect/:provider    → Disconnect account
 */

import express from "express";
import { chromium } from "playwright";
import { createClient } from "@supabase/supabase-js";
import { randomUUID } from "crypto";
import { resolveAuthorizedUserID, sendAuthError } from "../../lib/auth.js";
import { buildPlaywrightLaunchOptions } from "../../lib/playwright-runtime.js";

const router = express.Router();

// Live Playwright state stays in memory. Durable owner/status/expiry is persisted
// in Supabase so restarts fail cleanly instead of hanging client flows.
const activeSessions = new Map();
const CONNECT_SESSION_TTL_MS = 5 * 60 * 1000;

const PROVIDERS = {
  instacart: {
    name: "Instacart",
    loginUrl: "https://www.instacart.ca/login",
    homeUrl: "https://www.instacart.ca/store",
    domain: "instacart.ca",
    checkLoggedIn: (url) => !url.includes("login") && url.includes("instacart"),
  },
  walmart: {
    name: "Walmart",
    loginUrl: "https://www.walmart.ca/sign-in",
    homeUrl: "https://www.walmart.ca/grocery",
    domain: "walmart.ca",
    checkLoggedIn: (url) => !url.includes("sign-in") && url.includes("walmart"),
  },
};

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function getSupabase() {
  if (!SUPABASE_URL || !SUPABASE_KEY) {
    throw new Error("Provider connect requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY");
  }
  return createClient(SUPABASE_URL, SUPABASE_KEY);
}

function normalizeText(value) {
  return String(value ?? "").trim();
}

function connectSessionExpiresAt() {
  return new Date(Date.now() + CONNECT_SESSION_TTL_MS).toISOString();
}

function resolveServerBaseURL() {
  const configured = normalizeText(process.env.SERVER_URL).replace(/\/+$/, "");
  if (configured) return configured;
  if (process.env.NODE_ENV === "production") {
    throw new Error("SERVER_URL is required for provider connect in production");
  }
  return `http://localhost:${process.env.PORT || 8080}`;
}

async function upsertProviderConnectSession({
  sessionId,
  userId,
  provider,
  status,
  expiresAt,
  lastError = null,
}) {
  const supabase = getSupabase();
  const { error } = await supabase
    .from("provider_connect_sessions")
    .upsert({
      session_id: sessionId,
      user_id: userId,
      provider,
      status,
      expires_at: expiresAt ?? connectSessionExpiresAt(),
      last_error: lastError,
    }, {
      onConflict: "session_id",
    });

  if (error) throw error;
}

async function fetchProviderConnectSession(sessionId) {
  if (!sessionId) return null;
  const supabase = getSupabase();
  const { data, error } = await supabase
    .from("provider_connect_sessions")
    .select("*")
    .eq("session_id", sessionId)
    .maybeSingle();
  if (error) throw error;
  return data ?? null;
}

async function markProviderConnectSession(sessionId, status, lastError = null) {
  if (!sessionId) return;
  const supabase = getSupabase();
  await supabase
    .from("provider_connect_sessions")
    .update({
      status,
      last_error: lastError,
    })
    .eq("session_id", sessionId);
}

function providerSessionResponse(row) {
  const status = normalizeText(row?.status) || "expired";
  return {
    status,
    connected: status === "connected",
    expiresAt: row?.expires_at ?? null,
    lastError: row?.last_error ?? null,
  };
}

function isProviderAccountConnected(row = {}) {
  const isActive = row.is_active !== false;
  const loginStatus = String(row.login_status ?? "").trim().toLowerCase();
  return isActive && loginStatus === "logged_in";
}

// ── POST /v1/connect/:provider ─────────────────────────────────────────────────
/**
 * Start a connection session for a provider.
 * Returns a URL the user should open to log in.
 */
router.post("/connect/:provider", async (req, res) => {
  const { provider } = req.params;

  let auth;
  try {
    auth = await resolveAuthorizedUserID(req);
  } catch (error) {
    return sendAuthError(res, error, `connect/${provider}`);
  }

  const config = PROVIDERS[provider];
  if (!config) {
    return res.status(400).json({ 
      error: `Unknown provider: ${provider}`,
      available: Object.keys(PROVIDERS),
    });
  }

  const sessionId = randomUUID();
  const expiresAt = connectSessionExpiresAt();
  try {
    const baseUrl = resolveServerBaseURL();
    await upsertProviderConnectSession({
      sessionId,
      userId: auth.userID,
      provider,
      status: "pending",
      expiresAt,
    });
    
    // Launch browser
    const browser = await chromium.launch(buildPlaywrightLaunchOptions({
      headless: true,
      args: ["--disable-blink-features=AutomationControlled"],
    }));

    const context = await browser.newContext({
      viewport: { width: 390, height: 844 }, // iPhone-sized
      userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    });

    await context.addInitScript(() => {
      Object.defineProperty(navigator, 'webdriver', { get: () => false });
    });

    const page = await context.newPage();
    await page.goto(config.loginUrl, { waitUntil: 'domcontentloaded' });

    // Store session
    activeSessions.set(sessionId, {
      userId: auth.userID,
      provider,
      browser,
      context,
      page,
      status: 'pending',
      createdAt: Date.now(),
      expiresAt,
    });

    // Start monitoring for login completion
    monitorLogin(sessionId, config);

    const connectUrl = `${baseUrl}/v1/connect/${provider}/browser/${sessionId}`;

    return res.json({
      sessionId,
      connectUrl,
      provider: config.name,
      instructions: `Open the link to log in to your ${config.name} account. Once logged in, return to the app.`,
    });

  } catch (err) {
    await markProviderConnectSession(sessionId, "failed", err.message).catch(() => {});
    console.error(`[connect/${provider}] error:`, err.message);
    return res.status(500).json({ error: err.message });
  }
});

// ── GET /v1/connect/:provider/status ───────────────────────────────────────────
/**
 * Check connection status for a provider.
 */
router.get("/connect/:provider/status", async (req, res) => {
  const { provider } = req.params;
  const { sessionId } = req.query;
  let auth = null;

  if (req.headers.authorization || req.headers["x-user-id"] || req.query.user_id || req.query.userID) {
    try {
      auth = await resolveAuthorizedUserID(req);
    } catch (error) {
      return sendAuthError(res, error, `connect/${provider}/status`);
    }
  }

  // Check active session first
  if (sessionId && activeSessions.has(sessionId)) {
    const session = activeSessions.get(sessionId);
    if (auth?.userID && session.userId !== auth.userID) {
      return res.status(403).json({ error: "Session does not belong to this user" });
    }
    return res.json({
      status: session.status,
      connected: session.status === 'connected',
      expiresAt: session.expiresAt ?? null,
    });
  }

  if (sessionId) {
    try {
      const row = await fetchProviderConnectSession(String(sessionId));
      if (!row) {
        return res.json({ status: "expired", connected: false });
      }
      if (auth?.userID && row.user_id !== auth.userID) {
        return res.status(403).json({ error: "Session does not belong to this user" });
      }
      const expiresAt = row.expires_at ? new Date(row.expires_at) : null;
      const shouldExpire = row.status === "pending" && (!expiresAt || expiresAt <= new Date());
      if (shouldExpire) {
        await markProviderConnectSession(String(sessionId), "expired", "Provider login session expired");
        return res.json({ status: "expired", connected: false, expiresAt: row.expires_at });
      }
      if (row.status === "pending") {
        await markProviderConnectSession(String(sessionId), "expired", "Provider login browser is no longer active");
        return res.json({ status: "expired", connected: false, expiresAt: row.expires_at });
      }
      return res.json(providerSessionResponse(row));
    } catch (err) {
      console.error(`[connect/${provider}/status] session error:`, err.message);
      return res.status(500).json({ error: err.message });
    }
  }

  if (!auth?.userID) {
    return res.status(401).json({ error: "Authorization required" });
  }

  // Check database for existing connection
  try {
    const supabase = getSupabase();
    const { data } = await supabase
      .from("user_provider_accounts")
      .select("id, provider, login_status, last_used_at, is_active")
      .eq("user_id", auth.userID)
      .eq("provider", provider)
      .maybeSingle();

    if (isProviderAccountConnected(data)) {
      return res.json({
        status: 'connected',
        connected: true,
        lastUsed: data.last_used_at,
      });
    }

    return res.json({
      status: 'not_connected',
      connected: false,
    });

  } catch (err) {
    return res.json({
      status: 'not_connected',
      connected: false,
    });
  }
});

// ── GET /v1/connect/:provider/browser/:sessionId ───────────────────────────────
/**
 * Serve the browser proxy page.
 * This page shows the Playwright browser and forwards interactions.
 */
router.get("/connect/:provider/browser/:sessionId", async (req, res) => {
  const { provider, sessionId } = req.params;
  const session = activeSessions.get(sessionId);

  if (!session) {
    await markProviderConnectSession(sessionId, "expired", "Provider login browser is no longer active").catch(() => {});
    return res.status(404).send(`
      <html>
        <body style="font-family: -apple-system, sans-serif; padding: 40px; text-align: center;">
          <h2>Session Expired</h2>
          <p>Please go back to the app and try again.</p>
        </body>
      </html>
    `);
  }

  const config = PROVIDERS[provider];

  // Serve the browser proxy page
  res.send(`
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
  <title>Connect ${config.name}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, sans-serif;
      background: #f5f5f5;
      min-height: 100vh;
    }
    .header {
      background: #1a1a2e;
      color: white;
      padding: 16px 20px;
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .header h1 {
      font-size: 17px;
      font-weight: 600;
    }
    .status {
      margin-left: auto;
      padding: 4px 12px;
      border-radius: 12px;
      font-size: 13px;
      background: #ffd700;
      color: #1a1a2e;
    }
    .status.connected {
      background: #4ade80;
    }
    .browser-frame {
      width: 100%;
      height: calc(100vh - 120px);
      border: none;
      background: white;
    }
    .footer {
      background: white;
      padding: 16px 20px;
      text-align: center;
      border-top: 1px solid #e5e5e5;
    }
    .footer p {
      color: #666;
      font-size: 14px;
    }
    .success-overlay {
      display: none;
      position: fixed;
      inset: 0;
      background: rgba(0,0,0,0.8);
      justify-content: center;
      align-items: center;
      z-index: 100;
    }
    .success-overlay.show {
      display: flex;
    }
    .success-card {
      background: white;
      padding: 40px;
      border-radius: 20px;
      text-align: center;
      max-width: 300px;
    }
    .success-card .checkmark {
      font-size: 60px;
      margin-bottom: 20px;
    }
    .success-card h2 {
      margin-bottom: 10px;
    }
    .success-card p {
      color: #666;
      margin-bottom: 20px;
    }
    .success-card button {
      background: #1a1a2e;
      color: white;
      border: none;
      padding: 14px 28px;
      border-radius: 10px;
      font-size: 16px;
      cursor: pointer;
    }
  </style>
</head>
<body>
  <div class="header">
    <h1>Connect ${config.name}</h1>
    <span class="status" id="status">Waiting for login...</span>
  </div>
  
  <iframe 
    id="browser" 
    class="browser-frame" 
    src="/v1/connect/${provider}/frame/${sessionId}"
  ></iframe>
  
  <div class="footer">
    <p>Log in to your ${config.name} account above</p>
  </div>

  <div class="success-overlay" id="success">
    <div class="success-card">
      <div class="checkmark">✓</div>
      <h2>Connected!</h2>
      <p>Your ${config.name} account is now linked to Ounje.</p>
      <button onclick="window.close(); window.location.href='ounje://provider-connected/${provider}';">
        Return to App
      </button>
    </div>
  </div>

  <script>
    const sessionId = "${sessionId}";
    const provider = "${provider}";
    
    // Poll for connection status
    async function checkStatus() {
      try {
        const res = await fetch(\`/v1/connect/\${provider}/status?sessionId=\${sessionId}\`);
        const data = await res.json();
        
        if (data.connected || data.status === 'connected') {
          document.getElementById('status').textContent = 'Connected!';
          document.getElementById('status').classList.add('connected');
          document.getElementById('success').classList.add('show');
          return;
        }
      } catch (e) {}
      
      setTimeout(checkStatus, 2000);
    }
    
    checkStatus();
  </script>
</body>
</html>
  `);
});

// ── GET /v1/connect/:provider/frame/:sessionId ─────────────────────────────────
/**
 * Serve live screenshot of the browser.
 */
router.get("/connect/:provider/frame/:sessionId", async (req, res) => {
  const { sessionId } = req.params;
  const session = activeSessions.get(sessionId);

  if (!session || !session.page) {
    await markProviderConnectSession(sessionId, "expired", "Provider login browser is no longer active").catch(() => {});
    return res.status(404).send("Session not found");
  }

  // Serve a page that shows screenshots and captures clicks
  res.send(`
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <style>
    * { margin: 0; padding: 0; }
    body { background: #fff; overflow: hidden; }
    #screen { width: 100%; height: 100vh; object-fit: contain; cursor: pointer; }
    .loading { 
      position: fixed; inset: 0; 
      display: flex; align-items: center; justify-content: center;
      background: #f5f5f5;
    }
    .loading.hidden { display: none; }
  </style>
</head>
<body>
  <div class="loading" id="loading">Loading...</div>
  <img id="screen" alt="Browser">
  
  <script>
    const sessionId = "${sessionId}";
    const screen = document.getElementById('screen');
    const loading = document.getElementById('loading');
    let refreshing = false;
    
    async function refreshScreen() {
      if (refreshing) return;
      refreshing = true;
      
      try {
        const res = await fetch(\`/v1/connect/screenshot/\${sessionId}?t=\${Date.now()}\`);
        if (res.ok) {
          const blob = await res.blob();
          screen.src = URL.createObjectURL(blob);
          loading.classList.add('hidden');
        }
      } catch (e) {}
      
      refreshing = false;
      setTimeout(refreshScreen, 500);
    }
    
    screen.addEventListener('click', async (e) => {
      const rect = screen.getBoundingClientRect();
      const x = ((e.clientX - rect.left) / rect.width) * 390;
      const y = ((e.clientY - rect.top) / rect.height) * 844;
      
      await fetch(\`/v1/connect/click/\${sessionId}\`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ x, y })
      });
    });
    
    // Handle keyboard input
    document.addEventListener('keydown', async (e) => {
      await fetch(\`/v1/connect/key/\${sessionId}\`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ key: e.key })
      });
    });
    
    refreshScreen();
  </script>
</body>
</html>
  `);
});

// ── GET /v1/connect/screenshot/:sessionId ──────────────────────────────────────
router.get("/connect/screenshot/:sessionId", async (req, res) => {
  const { sessionId } = req.params;
  const session = activeSessions.get(sessionId);

  if (!session || !session.page) {
    return res.status(404).send("Session not found");
  }

  try {
    const screenshot = await session.page.screenshot({ type: 'jpeg', quality: 80 });
    res.set('Content-Type', 'image/jpeg');
    res.send(screenshot);
  } catch (err) {
    res.status(500).send("Screenshot failed");
  }
});

// ── POST /v1/connect/click/:sessionId ──────────────────────────────────────────
router.post("/connect/click/:sessionId", async (req, res) => {
  const { sessionId } = req.params;
  const { x, y } = req.body;
  const session = activeSessions.get(sessionId);

  if (!session || !session.page) {
    return res.status(404).json({ error: "Session not found" });
  }

  try {
    await session.page.mouse.click(x, y);
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── POST /v1/connect/key/:sessionId ────────────────────────────────────────────
router.post("/connect/key/:sessionId", async (req, res) => {
  const { sessionId } = req.params;
  const { key } = req.body;
  const session = activeSessions.get(sessionId);

  if (!session || !session.page) {
    return res.status(404).json({ error: "Session not found" });
  }

  try {
    await session.page.keyboard.press(key);
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── POST /v1/connect/:provider/save-session ────────────────────────────────────
/**
 * Save session cookies from the iOS app after user logs in.
 */
router.post("/connect/:provider/save-session", async (req, res) => {
  const { provider } = req.params;
  const { cookies } = req.body;

  let auth;
  try {
    auth = await resolveAuthorizedUserID(req);
  } catch (error) {
    return sendAuthError(res, error, `save-session/${provider}`);
  }

  if (!cookies || !Array.isArray(cookies) || cookies.length === 0) {
    return res.status(400).json({ error: "Non-empty cookies array required" });
  }

  const config = PROVIDERS[provider];
  if (!config) {
    return res.status(400).json({ error: `Unknown provider: ${provider}` });
  }

  try {
    const supabase = getSupabase();
    
    // Upsert the provider account with cookies
    const { error } = await supabase
      .from("user_provider_accounts")
      .upsert({
        user_id: auth.userID,
        provider: provider,
        session_cookies: JSON.stringify(cookies),
        login_status: 'logged_in',
        last_used_at: new Date().toISOString(),
        is_active: true,
      }, {
        onConflict: 'user_id,provider',
      });

    if (error) {
      console.error(`[save-session/${provider}] DB error:`, error);
      return res.status(500).json({ error: error.message });
    }

    console.log(`[save-session/${provider}] Saved ${cookies.length} cookies for user ${auth.userID}`);
    return res.json({ success: true, cookieCount: cookies.length });
  } catch (err) {
    console.error(`[save-session/${provider}] error:`, err);
    return res.status(500).json({ error: err.message });
  }
});

// ── DELETE /v1/connect/:provider ───────────────────────────────────────────────
/**
 * Disconnect a provider account.
 */
router.delete("/connect/:provider", async (req, res) => {
  const { provider } = req.params;

  let auth;
  try {
    auth = await resolveAuthorizedUserID(req);
  } catch (error) {
    return sendAuthError(res, error, `disconnect/${provider}`);
  }

  try {
    const supabase = getSupabase();
    await supabase
      .from("user_provider_accounts")
      .delete()
      .eq("user_id", auth.userID)
      .eq("provider", provider);

    return res.json({ success: true });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

// ── GET /v1/connect/providers ──────────────────────────────────────────────────
/**
 * List available providers and their connection status for a user.
 */
router.get("/connect/providers", async (req, res) => {
  let auth;
  try {
    auth = await resolveAuthorizedUserID(req);
  } catch (error) {
    return sendAuthError(res, error, "connect/providers");
  }

  const providers = Object.entries(PROVIDERS).map(([id, config]) => ({
    id,
    name: config.name,
    connected: false,
  }));

  try {
    const supabase = getSupabase();
    const { data } = await supabase
      .from("user_provider_accounts")
      .select("provider,is_active,login_status")
      .eq("user_id", auth.userID);

    if (data) {
      const connectedProviders = new Set(
        data
          .filter((row) => isProviderAccountConnected(row))
          .map((row) => row.provider)
      );
      providers.forEach(p => {
        p.connected = connectedProviders.has(p.id);
      });
    }
  } catch {}

  return res.json({ providers });
});

// ── Monitor login completion ───────────────────────────────────────────────────
async function monitorLogin(sessionId, config) {
  const session = activeSessions.get(sessionId);
  if (!session) return;

  let timeoutHandle = null;
  const checkInterval = setInterval(async () => {
    try {
      if (!activeSessions.has(sessionId)) {
        clearInterval(checkInterval);
        return;
      }

      const currentSession = activeSessions.get(sessionId);
      const currentUrl = currentSession.page.url();

      if (config.checkLoggedIn(currentUrl)) {
        console.log(`[connect] Login detected for session ${sessionId}`);
        
        // Save session to database
        const cookies = await currentSession.context.cookies();
        
        const supabase = getSupabase();
        await supabase
          .from("user_provider_accounts")
          .upsert({
            user_id: currentSession.userId,
            provider: currentSession.provider,
            provider_email: `connected-${Date.now()}`, // We don't know the email
            session_cookies: JSON.stringify(cookies),
            login_status: 'logged_in',
            last_used_at: new Date().toISOString(),
            is_active: true,
          }, {
            onConflict: 'user_id,provider',
          });

        currentSession.status = 'connected';
        activeSessions.set(sessionId, currentSession);
        await markProviderConnectSession(sessionId, "connected");

        // Clean up after a delay
        setTimeout(() => cleanupSession(sessionId), 30000);
        clearInterval(checkInterval);
        if (timeoutHandle) clearTimeout(timeoutHandle);
      }
    } catch (err) {
      console.error(`[connect] Monitor error:`, err.message);
    }
  }, 2000);

  // Timeout after 5 minutes
  timeoutHandle = setTimeout(() => {
    clearInterval(checkInterval);
    markProviderConnectSession(sessionId, "expired", "Provider login session expired").catch(() => {});
    cleanupSession(sessionId);
  }, 300000);
}

async function cleanupSession(sessionId) {
  const session = activeSessions.get(sessionId);
  if (session) {
    try {
      await session.browser.close();
    } catch {}
    activeSessions.delete(sessionId);
  }
}

export default router;
