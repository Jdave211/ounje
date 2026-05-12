import assert from "node:assert/strict";

import {
  deriveEntitlementFromAppStoreNotification,
  processAppStoreNotification,
} from "../lib/app-store-notifications.js";

const DAY_MS = 24 * 60 * 60 * 1000;
const NOW_MS = Date.UTC(2026, 4, 12, 12, 0, 0);
const USER_ID = "4ef93b7f-f7b4-4d9a-9b13-0c4ce63350a1";

class MockSupabase {
  constructor({ entitlements = [], failLedger = false } = {}) {
    this.entitlements = new Map(entitlements.map((row) => [row.user_id, { ...row }]));
    this.events = new Map();
    this.failLedger = failLedger;
  }

  from(table) {
    return new MockQuery(this, table);
  }
}

class MockQuery {
  constructor(store, table) {
    this.store = store;
    this.table = table;
    this.filters = [];
    this.pendingUpsert = null;
  }

  select() {
    return this;
  }

  eq(column, value) {
    this.filters.push([column, value]);
    return this;
  }

  limit() {
    return this;
  }

  async maybeSingle() {
    const rows = this.table === "app_user_entitlements"
      ? Array.from(this.store.entitlements.values())
      : Array.from(this.store.events.values());
    const row = rows.find((candidate) => this.filters.every(([column, value]) => candidate[column] === value));
    return { data: row ?? null, error: null };
  }

  upsert(payload) {
    if (this.table === "app_store_notification_events") {
      if (this.store.failLedger) {
        return Promise.resolve({ data: null, error: { code: "42P01", message: "app_store_notification_events does not exist" } });
      }
      this.store.events.set(payload.notification_uuid, { ...payload });
      return Promise.resolve({ data: payload, error: null });
    }

    this.pendingUpsert = payload;
    return this;
  }

  async single() {
    const row = { ...this.pendingUpsert, updated_at: new Date(NOW_MS).toISOString() };
    this.store.entitlements.set(row.user_id, row);
    return { data: row, error: null };
  }
}

function notification({
  type = "DID_RENEW",
  subtype = undefined,
  uuid = cryptoRandomUUID(type),
  status = 1,
} = {}) {
  return {
    notificationType: type,
    subtype,
    notificationUUID: uuid,
    signedDate: NOW_MS,
    data: {
      environment: "Sandbox",
      bundleId: "net.ounje",
      appAppleId: 1234567890,
      status,
    },
  };
}

function transaction(overrides = {}) {
  return {
    originalTransactionId: "200000000000001",
    transactionId: "200000000000099",
    bundleId: "net.ounje",
    productId: "net.ounje.plus.monthly",
    appAccountToken: USER_ID,
    purchaseDate: NOW_MS - DAY_MS,
    originalPurchaseDate: NOW_MS - DAY_MS,
    expiresDate: NOW_MS + DAY_MS,
    environment: "Sandbox",
    ...overrides,
  };
}

function renewal(overrides = {}) {
  return {
    originalTransactionId: "200000000000001",
    productId: "net.ounje.plus.monthly",
    autoRenewProductId: "net.ounje.plus.monthly",
    autoRenewStatus: 1,
    appAccountToken: USER_ID,
    environment: "Sandbox",
    ...overrides,
  };
}

function cryptoRandomUUID(seed) {
  return `test-${String(seed).toLowerCase().replaceAll("_", "-")}`;
}

async function run() {
  {
    const supabase = new MockSupabase();
    const result = await processAppStoreNotification({
      supabase,
      notification: notification({ type: "DID_RENEW" }),
      transactionInfo: transaction(),
      renewalInfo: renewal(),
      nowMs: NOW_MS,
    });
    assert.equal(result.effectiveTier, "plus");
    assert.equal(result.entitlement.status, "active");
    assert.equal(result.entitlement.metadata.cadence, "monthly");
    assert.equal(supabase.events.size, 1);
  }

  {
    const state = deriveEntitlementFromAppStoreNotification({
      notification: notification({ type: "DID_CHANGE_RENEWAL_STATUS", subtype: "AUTO_RENEW_DISABLED" }),
      transactionInfo: transaction(),
      renewalInfo: renewal({ autoRenewStatus: 0 }),
      nowMs: NOW_MS,
    });
    assert.equal(state.status, "active");
    assert.equal(state.metadata.notification_subtype, "AUTO_RENEW_DISABLED");
    assert.equal(state.metadata.auto_renew_status, 0);
  }

  {
    const supabase = new MockSupabase();
    const result = await processAppStoreNotification({
      supabase,
      notification: notification({ type: "EXPIRED", status: 2 }),
      transactionInfo: transaction({ expiresDate: NOW_MS - DAY_MS }),
      renewalInfo: renewal({ isInBillingRetryPeriod: false }),
      nowMs: NOW_MS,
    });
    assert.equal(result.effectiveTier, "free");
    assert.equal(result.entitlement.status, "expired");
  }

  {
    const supabase = new MockSupabase();
    const result = await processAppStoreNotification({
      supabase,
      notification: notification({ type: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD", status: 4 }),
      transactionInfo: transaction({ expiresDate: NOW_MS - 60_000 }),
      renewalInfo: renewal({ isInBillingRetryPeriod: true, gracePeriodExpiresDate: NOW_MS + DAY_MS }),
      nowMs: NOW_MS,
    });
    assert.equal(result.effectiveTier, "plus");
    assert.equal(result.entitlement.status, "active");
    assert.equal(result.entitlement.expires_at, new Date(NOW_MS + DAY_MS).toISOString());
  }

  {
    const supabase = new MockSupabase();
    const result = await processAppStoreNotification({
      supabase,
      notification: notification({ type: "REFUND", status: 5 }),
      transactionInfo: transaction({ revocationDate: NOW_MS - 1_000 }),
      renewalInfo: renewal(),
      nowMs: NOW_MS,
    });
    assert.equal(result.effectiveTier, "free");
    assert.equal(result.entitlement.status, "revoked");
  }

  {
    const supabase = new MockSupabase({
      entitlements: [{
        user_id: USER_ID,
        tier: "plus",
        status: "active",
        source: "app_store",
        product_id: "net.ounje.plus.monthly",
        transaction_id: "200000000000010",
        original_transaction_id: "200000000000001",
        expires_at: new Date(NOW_MS + DAY_MS).toISOString(),
        metadata: {},
      }],
    });
    const result = await processAppStoreNotification({
      supabase,
      notification: notification({ type: "DID_RENEW" }),
      transactionInfo: transaction({ appAccountToken: undefined }),
      renewalInfo: renewal({ appAccountToken: undefined }),
      nowMs: NOW_MS,
    });
    assert.equal(result.entitlement.user_id, USER_ID);
    assert.equal(result.effectiveTier, "plus");
  }

  {
    const supabase = new MockSupabase({
      entitlements: [{
        user_id: USER_ID,
        tier: "foundingLifetime",
        status: "active",
        source: "manual",
        product_id: null,
        transaction_id: null,
        original_transaction_id: "200000000000001",
        expires_at: null,
        metadata: {},
      }],
    });
    const result = await processAppStoreNotification({
      supabase,
      notification: notification({ type: "EXPIRED", status: 2 }),
      transactionInfo: transaction({ expiresDate: NOW_MS - DAY_MS }),
      renewalInfo: renewal(),
      nowMs: NOW_MS,
    });
    assert.equal(result.protectedManualEntitlement, true);
    assert.equal(result.effectiveTier, "foundingLifetime");
  }

  {
    const supabase = new MockSupabase({ failLedger: true });
    const result = await processAppStoreNotification({
      supabase,
      notification: notification({ type: "TEST" }),
      nowMs: NOW_MS,
    });
    assert.equal(result.testNotification, true);
    assert.equal(result.ledger.recorded, false);
  }
}

await run();
console.log("App Store notification tests passed.");
