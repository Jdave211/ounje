#!/usr/bin/env node
/**
 * Test browser-use session persistence
 * 
 * Usage:
 *   node server/scripts/test-browser-session.mjs [provider] [action]
 * 
 * Examples:
 *   node server/scripts/test-browser-session.mjs instacart login    # Create session, login manually
 *   node server/scripts/test-browser-session.mjs instacart verify   # Verify session persisted
 *   node server/scripts/test-browser-session.mjs walmart login
 *   node server/scripts/test-browser-session.mjs amazon login
 */

import "dotenv/config";

const BROWSER_USE_API_KEY = process.env.BROWSER_USE_API_KEY;
const BROWSER_USE_BASE = "https://api.browser-use.com/api/v3";

if (!BROWSER_USE_API_KEY) {
  console.error("❌ BROWSER_USE_API_KEY not set in .env");
  process.exit(1);
}

const PROVIDERS = {
  instacart: {
    name: "Instacart",
    loginUrl: "https://www.instacart.com/login",
    homeUrl: "https://www.instacart.com/store",
    domains: ["*.instacart.com"],
    checkLoggedIn: "Check if logged in by looking for account menu or user icon in the header",
  },
  walmart: {
    name: "Walmart",
    loginUrl: "https://www.walmart.com/account/login",
    homeUrl: "https://www.walmart.com/grocery",
    domains: ["*.walmart.com"],
    checkLoggedIn: "Check if logged in by looking for 'Hi, [name]' or account icon in header",
  },
  amazon: {
    name: "Amazon Fresh",
    loginUrl: "https://www.amazon.com/ap/signin",
    homeUrl: "https://www.amazon.com/alm/storefront?almBrandId=QW1hem9uIEZyZXNo",
    domains: ["*.amazon.com"],
    checkLoggedIn: "Check if logged in by looking for 'Hello, [name]' in the header",
  },
  target: {
    name: "Target",
    loginUrl: "https://www.target.com/login",
    homeUrl: "https://www.target.com/c/grocery/-/N-5xt1a",
    domains: ["*.target.com"],
    checkLoggedIn: "Check if logged in by looking for account circle or name in header",
  },
};

function headers() {
  return {
    "X-Browser-Use-API-Key": BROWSER_USE_API_KEY,
    "Content-Type": "application/json",
  };
}

async function createProfile(name) {
  console.log(`\n📁 Creating browser profile: ${name}`);
  
  const resp = await fetch(`${BROWSER_USE_BASE}/profiles`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify({ name }),
  });

  if (!resp.ok) {
    const err = await resp.text();
    throw new Error(`Failed to create profile: ${err}`);
  }

  const profile = await resp.json();
  console.log(`   Profile ID: ${profile.id}`);
  return profile;
}

async function getProfile(name) {
  console.log(`\n🔍 Looking for existing profile: ${name}`);
  
  const resp = await fetch(`${BROWSER_USE_BASE}/profiles`, {
    headers: headers(),
  });

  if (!resp.ok) {
    return null;
  }

  const profiles = await resp.json();
  const existing = profiles.data?.find(p => p.name === name);
  
  if (existing) {
    console.log(`   Found profile ID: ${existing.id}`);
    return existing;
  }
  
  console.log(`   No existing profile found`);
  return null;
}

async function createSession(profileId) {
  console.log(`\n🌐 Creating browser session...`);
  
  const resp = await fetch(`${BROWSER_USE_BASE}/sessions`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify({
      profileId: profileId,  // camelCase per API spec
      keepAlive: true,       // Keep session alive for manual login
    }),
  });

  if (!resp.ok) {
    const err = await resp.text();
    throw new Error(`Failed to create session: ${err}`);
  }

  const session = await resp.json();
  console.log(`   Session ID: ${session.id}`);
  console.log(`   Status: ${session.status}`);
  console.log(`   Live URL: ${session.liveUrl || "(not yet available)"}`);
  return session;
}

async function runTask(sessionId, task, options = {}) {
  const body = {
    task,
    sessionId: sessionId,  // camelCase per API spec
    model: "claude-sonnet-4.6",
    keepAlive: true,       // Keep session alive after task
    ...options,
  };

  const resp = await fetch(`${BROWSER_USE_BASE}/sessions`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    const err = await resp.text();
    throw new Error(`Task failed: ${err}`);
  }

  return pollSession(await resp.json());
}

async function pollSession(session) {
  const maxWait = 180_000; // 3 minutes
  const start = Date.now();
  
  while (Date.now() - start < maxWait) {
    const resp = await fetch(`${BROWSER_USE_BASE}/sessions/${session.id}`, {
      headers: headers(),
    });

    if (!resp.ok) {
      throw new Error(`Failed to poll session`);
    }

    const data = await resp.json();
    
    if (data.status === "completed") {
      return data;
    }
    
    if (data.status === "failed" || data.status === "cancelled") {
      throw new Error(`Session ${data.status}: ${data.error || "Unknown"}`);
    }

    // Still running
    process.stdout.write(".");
    await sleep(2000);
  }

  throw new Error("Session timed out");
}

async function stopSession(sessionId) {
  await fetch(`${BROWSER_USE_BASE}/sessions/${sessionId}/stop`, {
    method: "POST",
    headers: headers(),
  });
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

// ── Main ───────────────────────────────────────────────────────────────────────

async function loginFlow(provider) {
  const config = PROVIDERS[provider];
  if (!config) {
    console.error(`Unknown provider: ${provider}`);
    console.log(`Available: ${Object.keys(PROVIDERS).join(", ")}`);
    process.exit(1);
  }

  const profileName = `ounje-${provider}-test`;
  
  // Get or create profile
  let profile = await getProfile(profileName);
  if (!profile) {
    profile = await createProfile(profileName);
  }

  // Create session with profile
  const session = await createSession(profile.id);

  console.log(`\n🔗 Live URL (watch the browser):`);
  console.log(`   ${session.liveUrl}`);
  console.log(`\n⏳ Opening ${config.name} login page...`);

  try {
    // Navigate to login page
    const navResult = await runTask(session.id, `
      Go to ${config.loginUrl}
      Wait for the page to fully load.
      Return { "ready": true, "currentUrl": "the current URL" }
    `, {
      startUrl: config.loginUrl,
      allowedDomains: config.domains,
    });

    console.log(`\n✅ Login page loaded`);
    console.log(`\n${"═".repeat(60)}`);
    console.log(`\n👆 NOW: Open the live URL above and log in manually`);
    console.log(`   The browser will wait for you to complete login.`);
    console.log(`\n   Live URL: ${session.liveUrl}`);
    console.log(`\n${"═".repeat(60)}`);
    
    // Wait for user to log in (check every 10 seconds for up to 5 minutes)
    console.log(`\n⏳ Waiting for you to log in (up to 5 minutes)...`);
    
    let loggedIn = false;
    const maxAttempts = 30;
    
    for (let i = 0; i < maxAttempts; i++) {
      await sleep(10_000);
      
      try {
        const checkResult = await runTask(session.id, `
          ${config.checkLoggedIn}
          
          Return a JSON object:
          {
            "loggedIn": true or false,
            "userName": "the user's name if visible, or null",
            "currentUrl": "the current URL"
          }
        `, {
          allowedDomains: config.domains,
        });

        const output = checkResult.output;
        if (output?.loggedIn) {
          loggedIn = true;
          console.log(`\n✅ Login detected!`);
          if (output.userName) {
            console.log(`   Logged in as: ${output.userName}`);
          }
          break;
        }
      } catch {
        // Check failed, keep waiting
      }
      
      process.stdout.write(".");
    }

    if (!loggedIn) {
      console.log(`\n⚠️  Login not detected after 5 minutes`);
      console.log(`   The session will be saved anyway.`);
    }

    // Session is automatically saved to the profile
    console.log(`\n💾 Session saved to profile: ${profileName}`);
    console.log(`   Profile ID: ${profile.id}`);
    console.log(`\n✅ Done! Run with 'verify' to test session persistence:`);
    console.log(`   node server/scripts/test-browser-session.mjs ${provider} verify`);

  } finally {
    await stopSession(session.id);
  }
}

async function verifyFlow(provider) {
  const config = PROVIDERS[provider];
  if (!config) {
    console.error(`Unknown provider: ${provider}`);
    process.exit(1);
  }

  const profileName = `ounje-${provider}-test`;
  
  // Get existing profile
  const profile = await getProfile(profileName);
  if (!profile) {
    console.error(`\n❌ No profile found for ${provider}`);
    console.log(`   Run login first: node server/scripts/test-browser-session.mjs ${provider} login`);
    process.exit(1);
  }

  // Create session with existing profile
  const session = await createSession(profile.id);

  console.log(`\n🔗 Live URL:`);
  console.log(`   ${session.liveUrl}`);
  console.log(`\n⏳ Checking if session persisted...`);

  try {
    const result = await runTask(session.id, `
      Go to ${config.homeUrl}
      Wait for the page to load.
      
      ${config.checkLoggedIn}
      
      Return:
      {
        "loggedIn": true or false,
        "userName": "user's name if visible",
        "currentUrl": "current URL"
      }
    `, {
      startUrl: config.homeUrl,
      allowedDomains: config.domains,
    });

    const output = result.output;
    
    console.log(`\n${"═".repeat(60)}`);
    if (output?.loggedIn) {
      console.log(`\n✅ SESSION PERSISTED SUCCESSFULLY!`);
      console.log(`   Provider: ${config.name}`);
      if (output.userName) {
        console.log(`   User: ${output.userName}`);
      }
      console.log(`   URL: ${output.currentUrl}`);
      console.log(`\n   The browser remembered the login session.`);
      console.log(`   Future orders can skip the login step.`);
    } else {
      console.log(`\n❌ SESSION DID NOT PERSIST`);
      console.log(`   The browser is not logged in.`);
      console.log(`   This could mean:`);
      console.log(`   - The provider logged you out`);
      console.log(`   - Cookies weren't saved properly`);
      console.log(`   - The provider requires re-auth`);
    }
    console.log(`\n${"═".repeat(60)}`);

  } finally {
    await stopSession(session.id);
  }
}

async function listProfiles() {
  console.log(`\n📋 Listing all browser profiles...`);
  
  const resp = await fetch(`${BROWSER_USE_BASE}/profiles`, {
    headers: headers(),
  });

  if (!resp.ok) {
    console.error("Failed to list profiles");
    return;
  }

  const profiles = await resp.json();
  
  if (!profiles.data?.length) {
    console.log(`   No profiles found`);
    return;
  }

  console.log(`\n   Found ${profiles.data.length} profile(s):\n`);
  for (const p of profiles.data) {
    console.log(`   - ${p.name}`);
    console.log(`     ID: ${p.id}`);
    console.log(`     Created: ${p.created_at}`);
    console.log();
  }
}

// ── CLI ────────────────────────────────────────────────────────────────────────

const [,, provider, action = "login"] = process.argv;

if (!provider || provider === "list") {
  await listProfiles();
  console.log(`\nUsage:`);
  console.log(`  node server/scripts/test-browser-session.mjs <provider> login   # Log in and save session`);
  console.log(`  node server/scripts/test-browser-session.mjs <provider> verify  # Verify session persists`);
  console.log(`  node server/scripts/test-browser-session.mjs list               # List saved profiles`);
  console.log(`\nProviders: ${Object.keys(PROVIDERS).join(", ")}`);
  process.exit(0);
}

if (action === "login") {
  await loginFlow(provider);
} else if (action === "verify") {
  await verifyFlow(provider);
} else {
  console.error(`Unknown action: ${action}`);
  console.log(`Use 'login' or 'verify'`);
  process.exit(1);
}
