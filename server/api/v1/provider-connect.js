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

const router = express.Router();

// In-memory session store (replace with Redis in production)
const activeSessions = new Map();

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
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_ANON_KEY;

function getSupabase() {
  if (!SUPABASE_URL || !SUPABASE_KEY) {
    throw new Error("Supabase not configured - need SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY or SUPABASE_ANON_KEY");
  }
  return createClient(SUPABASE_URL, SUPABASE_KEY);
}

// ── POST /v1/connect/:provider ─────────────────────────────────────────────────
/**
 * Start a connection session for a provider.
 * Returns a URL the user should open to log in.
 */
router.post("/connect/:provider", async (req, res) => {
  const { provider } = req.params;
  const userId = req.headers["x-user-id"];

  if (!userId) {
    return res.status(401).json({ error: "User ID required" });
  }

  const config = PROVIDERS[provider];
  if (!config) {
    return res.status(400).json({ 
      error: `Unknown provider: ${provider}`,
      available: Object.keys(PROVIDERS),
    });
  }

  try {
    const sessionId = randomUUID();
    
    // Launch browser
    const browser = await chromium.launch({
      headless: true,
      args: ['--disable-blink-features=AutomationControlled', '--no-sandbox'],
    });

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
      userId,
      provider,
      browser,
      context,
      page,
      status: 'pending',
      createdAt: Date.now(),
    });

    // Start monitoring for login completion
    monitorLogin(sessionId, config);

    // Build the connect URL
    const baseUrl = process.env.SERVER_URL || `http://localhost:${process.env.PORT || 8080}`;
    const connectUrl = `${baseUrl}/v1/connect/${provider}/browser/${sessionId}`;

    return res.json({
      sessionId,
      connectUrl,
      provider: config.name,
      instructions: `Open the link to log in to your ${config.name} account. Once logged in, return to the app.`,
    });

  } catch (err) {
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
  const userId = req.headers["x-user-id"];
  const { sessionId } = req.query;

  if (!userId) {
    return res.status(401).json({ error: "User ID required" });
  }

  // Check active session first
  if (sessionId && activeSessions.has(sessionId)) {
    const session = activeSessions.get(sessionId);
    return res.json({
      status: session.status,
      connected: session.status === 'connected',
    });
  }

  // Check database for existing connection
  try {
    const supabase = getSupabase();
    const { data } = await supabase
      .from("user_provider_accounts")
      .select("id, provider, login_status, last_used_at")
      .eq("user_id", userId)
      .eq("provider", provider)
      .single();

    if (data) {
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
  const userId = req.headers["x-user-id"];
  const { cookies } = req.body;

  if (!userId) {
    return res.status(401).json({ error: "User ID required" });
  }

  if (!cookies || !Array.isArray(cookies)) {
    return res.status(400).json({ error: "Cookies array required" });
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
        user_id: userId,
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

    console.log(`[save-session/${provider}] Saved ${cookies.length} cookies for user ${userId}`);
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
  const userId = req.headers["x-user-id"];

  if (!userId) {
    return res.status(401).json({ error: "User ID required" });
  }

  try {
    const supabase = getSupabase();
    await supabase
      .from("user_provider_accounts")
      .delete()
      .eq("user_id", userId)
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
  const userId = req.headers["x-user-id"];

  const providers = Object.entries(PROVIDERS).map(([id, config]) => ({
    id,
    name: config.name,
    connected: false,
  }));

  if (userId) {
    try {
      const supabase = getSupabase();
      const { data } = await supabase
        .from("user_provider_accounts")
        .select("provider")
        .eq("user_id", userId);

      if (data) {
        const connectedProviders = new Set(data.map(d => d.provider));
        providers.forEach(p => {
          p.connected = connectedProviders.has(p.id);
        });
      }
    } catch {}
  }

  return res.json({ providers });
});

// ── Monitor login completion ───────────────────────────────────────────────────
async function monitorLogin(sessionId, config) {
  const session = activeSessions.get(sessionId);
  if (!session) return;

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
          }, {
            onConflict: 'user_id,provider',
          });

        currentSession.status = 'connected';
        activeSessions.set(sessionId, currentSession);

        // Clean up after a delay
        setTimeout(() => cleanupSession(sessionId), 30000);
        clearInterval(checkInterval);
      }
    } catch (err) {
      console.error(`[connect] Monitor error:`, err.message);
    }
  }, 2000);

  // Timeout after 5 minutes
  setTimeout(() => {
    clearInterval(checkInterval);
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
