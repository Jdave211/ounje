/**
 * Browser-Use Agent Provider
 * 
 * LLM-powered browser automation for grocery ordering.
 * Uses browser-use.com cloud API for:
 *   - Anti-bot bypass (stealth browsers, residential proxies)
 *   - CAPTCHA solving
 *   - Session persistence across tasks
 *
 * Supported providers:
 *   - Walmart
 *   - Amazon Fresh
 *   - Target (Same Day Delivery)
 *
 * Flow:
 *   1. createSession()     → Start browser session, optionally with saved profile
 *   2. buildCart()         → Search + add items to provider cart
 *   3. getCartSummary()    → Extract current cart state
 *   4. selectDeliverySlot() → Pick delivery window
 *   5. prepareCheckout()   → Navigate to checkout, stop before payment
 *   6. stopSession()       → End session (or keep alive for confirmation)
 */

const BROWSER_USE_BASE = "https://api.browser-use.com/api/v3";

// ── Configuration ──────────────────────────────────────────────────────────────

const BROWSER_USE_API_KEY = process.env.BROWSER_USE_API_KEY ?? "";

function headers() {
  return {
    "X-Browser-Use-API-Key": BROWSER_USE_API_KEY,
    "Content-Type": "application/json",
  };
}

// ── Provider Configs ───────────────────────────────────────────────────────────

const PROVIDER_CONFIGS = {
  instacart: {
    name: "Instacart",
    startUrl: "https://www.instacart.ca/store/s",
    domains: ["*.instacart.ca"],
    addressPrompt: (addr) => `
      Set delivery address to: ${addr.line1}, ${addr.city}, ${addr.region} ${addr.postalCode}
      If the address selector appears, confirm the matching saved address before continuing.
    `,
    searchPrompt: (items) => `
      Review the current Instacart cart and continue building it with these grocery items:
      ${items.map((i, idx) => `${idx + 1}. ${i.name} (quantity: ${Math.ceil(i.amount || 1)})`).join("\n")}

      For each item:
      - Search for the best product match
      - Prefer the correct grocery form for the recipe context
      - Add the product only if it is a safe match
      - Leave obviously wrong products out and note any unresolved items
    `,
  },
  walmart: {
    name: "Walmart",
    startUrl: "https://www.walmart.com/grocery",
    domains: ["*.walmart.com"],
    addressPrompt: (addr) => `
      Set delivery address to: ${addr.line1}, ${addr.city}, ${addr.region} ${addr.postalCode}
      If prompted to choose a store, select the closest Walmart that offers grocery delivery.
    `,
    searchPrompt: (items) => `
      Search for and add these grocery items to your cart:
      ${items.map((i, idx) => `${idx + 1}. ${i.name} (quantity: ${Math.ceil(i.amount || 1)})`).join("\n")}
      
      For each item:
      - Use the search bar to find the product
      - If the exact item isn't found, search for a close alternative
      - Click "Add to cart" and set the correct quantity
      - Note any substitutions you made
    `,
  },
  amazonFresh: {
    name: "Amazon Fresh",
    startUrl: "https://www.amazon.com/alm/storefront?almBrandId=QW1hem9uIEZyZXNo",
    domains: ["*.amazon.com"],
    addressPrompt: (addr) => `
      Make sure delivery address is set to: ${addr.line1}, ${addr.city}, ${addr.region} ${addr.postalCode}
      If you need to change the address, click on the delivery location at the top.
    `,
    searchPrompt: (items) => `
      Add these grocery items to your Amazon Fresh cart:
      ${items.map((i, idx) => `${idx + 1}. ${i.name} (quantity: ${Math.ceil(i.amount || 1)})`).join("\n")}
      
      For each item:
      - Search in Amazon Fresh (make sure you're in the Fresh section)
      - Add the closest matching product
      - Adjust quantity as needed
      - Note any items that weren't available
    `,
  },
  target: {
    name: "Target",
    startUrl: "https://www.target.com/c/grocery/-/N-5xt1a",
    domains: ["*.target.com"],
    addressPrompt: (addr) => `
      Set delivery address to: ${addr.line1}, ${addr.city}, ${addr.region} ${addr.postalCode}
      Choose "Same Day Delivery" if available for groceries.
    `,
    searchPrompt: (items) => `
      Add these grocery items to your Target cart for same-day delivery:
      ${items.map((i, idx) => `${idx + 1}. ${i.name} (quantity: ${Math.ceil(i.amount || 1)})`).join("\n")}
      
      For each item:
      - Search for the product
      - Select "Same Day Delivery" option if available
      - Add to cart with the correct quantity
    `,
  },
};

// ── Session Management ─────────────────────────────────────────────────────────

/**
 * Create a new browser session for a provider.
 * 
 * @param {Object} params
 * @param {string} params.provider - "walmart" | "amazonFresh" | "target"
 * @param {string} [params.profileId] - Reuse a saved browser profile (logged-in session)
 * @param {Object} [params.proxy] - Custom proxy configuration
 * @returns {Promise<{sessionId: string, liveUrl: string}>}
 */
export async function createSession({ provider, profileId, proxy }) {
  if (!BROWSER_USE_API_KEY) {
    throw new Error("BROWSER_USE_API_KEY not configured");
  }

  const config = PROVIDER_CONFIGS[provider];
  if (!config) {
    throw new Error(`Unknown provider: ${provider}`);
  }

  const body = {
    ...(profileId && { profile_id: profileId }),
    ...(proxy && { custom_proxy: proxy }),
  };

  const resp = await fetch(`${BROWSER_USE_BASE}/sessions`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => resp.statusText);
    throw new Error(`browser-use createSession ${resp.status}: ${err}`);
  }

  const data = await resp.json();
  return {
    sessionId: data.id,
    liveUrl: data.live_url,
    status: data.status,
  };
}

/**
 * Run a task in an existing session.
 * Blocks until the task completes (up to 4 hours).
 * 
 * @param {Object} params
 * @param {string} params.sessionId
 * @param {string} params.task - Natural language instruction
 * @param {string} [params.startUrl] - Navigate here before starting
 * @param {string[]} [params.allowedDomains] - Restrict navigation
 * @param {Object} [params.outputSchema] - JSON schema for structured output
 * @param {Object} [params.secrets] - Credentials for auto-fill
 * @returns {Promise<Object>} Task result
 */
export async function runTask({
  sessionId,
  task,
  startUrl,
  allowedDomains,
  outputSchema,
  secrets,
}) {
  const body = {
    task,
    session_id: sessionId,
    model: "claude-sonnet-4.6",
    ...(startUrl && { start_url: startUrl }),
    ...(allowedDomains && { allowed_domains: allowedDomains }),
    ...(outputSchema && { output_schema: outputSchema }),
    ...(secrets && { secrets }),
  };

  const resp = await fetch(`${BROWSER_USE_BASE}/sessions`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => resp.statusText);
    throw new Error(`browser-use runTask ${resp.status}: ${err}`);
  }

  const session = await resp.json();

  // Poll for completion
  return await pollSession(session.id);
}

/**
 * Poll a session until it completes.
 */
async function pollSession(sessionId, maxWaitMs = 300_000) {
  const startTime = Date.now();
  const pollInterval = 2000;

  while (Date.now() - startTime < maxWaitMs) {
    const resp = await fetch(`${BROWSER_USE_BASE}/sessions/${sessionId}`, {
      headers: headers(),
    });

    if (!resp.ok) {
      throw new Error(`browser-use getSession ${resp.status}`);
    }

    const session = await resp.json();

    if (session.status === "completed") {
      return {
        output: session.output,
        steps: session.steps ?? [],
        screenshotUrl: session.screenshot_url,
        duration: session.duration_ms,
      };
    }

    if (session.status === "failed" || session.status === "cancelled") {
      throw new Error(`Session ${session.status}: ${session.error ?? "Unknown error"}`);
    }

    await sleep(pollInterval);
  }

  throw new Error("Session timed out");
}

/**
 * Stop a session (releases resources).
 */
export async function stopSession(sessionId) {
  const resp = await fetch(`${BROWSER_USE_BASE}/sessions/${sessionId}/stop`, {
    method: "POST",
    headers: headers(),
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => resp.statusText);
    throw new Error(`browser-use stopSession ${resp.status}: ${err}`);
  }

  return await resp.json();
}

// ── Grocery Cart Operations ────────────────────────────────────────────────────

/**
 * Build a grocery cart on a provider.
 * This is the main entry point for cart building.
 * 
 * @param {Object} params
 * @param {string} params.provider - "walmart" | "amazonFresh" | "target"
 * @param {Array} params.items - GroceryItem[] from Ounje
 * @param {Object} params.address - Delivery address
 * @param {string} [params.profileId] - Logged-in browser profile
 * @param {Object} [params.credentials] - Login credentials if no profile
 * @returns {Promise<CartBuildResult>}
 */
export async function buildCart({
  provider,
  items,
  address,
  profileId,
  credentials,
}) {
  const config = PROVIDER_CONFIGS[provider];
  if (!config) {
    throw new Error(`Unknown provider: ${provider}`);
  }

  // Create session
  const { sessionId, liveUrl } = await createSession({ provider, profileId });

  try {
    // Step 1: Navigate and set address
    const addressTask = `
      Go to ${config.startUrl}
      ${config.addressPrompt(address)}
      Confirm the address is set correctly before proceeding.
    `;

    await runTask({
      sessionId,
      task: addressTask,
      startUrl: config.startUrl,
      allowedDomains: config.domains,
    });

    // Step 2: Add items to cart
    const cartTask = `
      ${config.searchPrompt(items)}
      
      After adding all items, go to the cart page.
      
      Return a JSON object with this structure:
      {
        "itemsAdded": [
          {
            "requested": "original item name",
            "matched": "product name added to cart",
            "price": 5.99,
            "quantity": 2,
            "status": "found" | "substituted" | "not_found"
          }
        ],
        "itemsMissing": ["item names that couldn't be found"],
        "subtotal": 45.67,
        "cartUrl": "current URL"
      }
    `;

    const cartResult = await runTask({
      sessionId,
      task: cartTask,
      allowedDomains: config.domains,
      outputSchema: {
        type: "object",
        properties: {
          itemsAdded: {
            type: "array",
            items: {
              type: "object",
              properties: {
                requested: { type: "string" },
                matched: { type: "string" },
                price: { type: "number" },
                quantity: { type: "number" },
                status: { type: "string", enum: ["found", "substituted", "not_found"] },
              },
            },
          },
          itemsMissing: { type: "array", items: { type: "string" } },
          subtotal: { type: "number" },
          cartUrl: { type: "string" },
        },
      },
    });

    return {
      sessionId,
      liveUrl,
      provider,
      ...cartResult.output,
      screenshotUrl: cartResult.screenshotUrl,
    };
  } catch (error) {
    // Don't stop session on error - allow retry
    throw error;
  }
}

/**
 * Get available delivery slots for a cart.
 */
export async function getDeliverySlots({ sessionId, provider }) {
  const config = PROVIDER_CONFIGS[provider];

  const task = `
    Navigate to the delivery slot selection page.
    Extract all available delivery windows.
    
    Return a JSON object:
    {
      "slots": [
        {
          "date": "2026-04-03",
          "timeRange": "9am - 11am",
          "fee": 9.95,
          "available": true
        }
      ],
      "selectedSlot": null
    }
  `;

  const result = await runTask({
    sessionId,
    task,
    allowedDomains: config.domains,
    outputSchema: {
      type: "object",
      properties: {
        slots: {
          type: "array",
          items: {
            type: "object",
            properties: {
              date: { type: "string" },
              timeRange: { type: "string" },
              fee: { type: "number" },
              available: { type: "boolean" },
            },
          },
        },
        selectedSlot: { type: "object", nullable: true },
      },
    },
  });

  return result.output;
}

/**
 * Select a delivery slot.
 */
export async function selectDeliverySlot({ sessionId, provider, date, timeRange }) {
  const config = PROVIDER_CONFIGS[provider];

  const task = `
    Select the delivery slot for ${date} during ${timeRange}.
    Click to confirm the selection.
    Return { "selected": true, "date": "${date}", "timeRange": "${timeRange}" } if successful.
  `;

  const result = await runTask({
    sessionId,
    task,
    allowedDomains: config.domains,
  });

  return result.output;
}

/**
 * Prepare checkout - navigate to final review before payment.
 * This is where we stop for human confirmation.
 */
export async function prepareCheckout({ sessionId, provider, startUrl }) {
  const config = PROVIDER_CONFIGS[provider];

  const task = `
    Proceed to checkout.
    Navigate through any intermediate steps until you reach the final order review page.
    STOP before entering payment information or clicking "Place Order".
    
    Extract the final order summary:
    {
      "subtotal": 45.67,
      "deliveryFee": 9.95,
      "serviceFee": 2.99,
      "tax": 4.50,
      "total": 63.11,
      "deliverySlot": "Tomorrow 9am-11am",
      "deliveryAddress": "123 Main St...",
      "itemCount": 12,
      "checkoutUrl": "current URL",
      "readyToSubmit": true
    }
  `;

  const result = await runTask({
    sessionId,
    task,
    startUrl: startUrl ?? config.startUrl,
    allowedDomains: config.domains,
    outputSchema: {
      type: "object",
      properties: {
        subtotal: { type: "number" },
        deliveryFee: { type: "number" },
        serviceFee: { type: "number" },
        tax: { type: "number" },
        total: { type: "number" },
        deliverySlot: { type: "string" },
        deliveryAddress: { type: "string" },
        itemCount: { type: "number" },
        checkoutUrl: { type: "string" },
        readyToSubmit: { type: "boolean" },
      },
    },
  });

  return {
    ...result.output,
    screenshotUrl: result.screenshotUrl,
  };
}

// ── Account Management ─────────────────────────────────────────────────────────

/**
 * Login to a provider account.
 * Uses credentials from Lumbox vault or direct input.
 */
function assertProviderCredentialAutomationAllowed() {
  const explicitlyAllowed = String(process.env.ALLOW_PROVIDER_CREDENTIAL_AGENT_TASKS ?? "").trim().toLowerCase() === "true";
  if (process.env.NODE_ENV === "production" && !explicitlyAllowed) {
    throw new Error("Provider credential browser-agent tasks are disabled in production");
  }
}

export async function loginToProvider({
  sessionId,
  provider,
  email,
  password,
  phoneForOtp,
}) {
  assertProviderCredentialAutomationAllowed();
  const config = PROVIDER_CONFIGS[provider];

  const task = `
    Log in to ${config.name} using the provider secrets supplied out-of-band.
    
    If 2FA/OTP is required:
    - The OTP will be sent to the configured account contact.
    - Wait for the OTP and enter it when prompted
    
    After successful login, confirm you're on the main page.
    Return { "loggedIn": true, "username": "displayed name if visible" }
  `;

  const result = await runTask({
    sessionId,
    task,
    startUrl: config.startUrl,
    allowedDomains: config.domains,
    secrets: {
      [getProviderDomain(provider)]: {
        email,
        password,
      },
    },
  });

  return result.output;
}

/**
 * Create a new account on a provider.
 * Requires email inbox and phone for verification.
 */
export async function createProviderAccount({
  sessionId,
  provider,
  email,
  password,
  firstName,
  lastName,
  phone,
  address,
}) {
  assertProviderCredentialAutomationAllowed();
  const config = PROVIDER_CONFIGS[provider];

  const task = `
    Create a new ${config.name} account:
    
    1. Navigate to the sign-up page
    2. Fill in the registration form using the provider secrets and profile data supplied out-of-band.
    
    3. Complete email verification if required
       - Check for verification email
       - Click the verification link or enter the code
    
    4. Complete phone verification if required
       - Enter the OTP sent to ${phone}
    
    5. Set delivery address to:
       ${address.line1}, ${address.city}, ${address.region} ${address.postalCode}
    
    Return:
    {
      "accountCreated": true,
      "verified": true,
      "addressSet": true
    }
  `;

  const result = await runTask({
    sessionId,
    task,
    startUrl: config.startUrl,
    allowedDomains: [...config.domains, "*.google.com", "*.lumbox.co"],
  });

  return result.output;
}

// ── Helpers ────────────────────────────────────────────────────────────────────

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getProviderDomain(provider) {
  const domains = {
    walmart: "walmart.com",
    amazonFresh: "amazon.com",
    target: "target.com",
  };
  return domains[provider] ?? provider;
}

/**
 * Normalize ingredient names for better search results.
 */
export function normalizeForSearch(name) {
  return name
    .toLowerCase()
    .replace(/\b(fresh|organic|large|small|medium|extra|ripe|boneless|skinless)\b/gi, "")
    .replace(/\b(chopped|sliced|diced|minced|grated|shredded|divided|softened|melted)\b/gi, "")
    .replace(/[\d\/.,()-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

// ── Exports ────────────────────────────────────────────────────────────────────

export const SUPPORTED_PROVIDERS = Object.keys(PROVIDER_CONFIGS);

export function getProviderConfig(provider) {
  return PROVIDER_CONFIGS[provider] ?? null;
}
