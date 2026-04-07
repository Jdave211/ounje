# User Verification Infrastructure

This document describes the email and phone verification systems used by the grocery ordering agent to create and manage provider accounts on behalf of users.

## Overview

When users want to order groceries through Ounje, we need to:
1. Create accounts on providers (Walmart, Amazon, Target) on their behalf
2. Handle email verification during signup
3. Handle SMS/phone verification during signup
4. Store credentials securely for future sessions

## Email Verification: Lumbox

**What it does:** Creates programmable email inboxes that can receive and parse verification emails.

**Why we need it:** When creating a Walmart account, the user needs to verify their email. We create a dedicated inbox, use it for signup, and programmatically extract the verification code.

### Setup

1. Sign up at [lumbox.co](https://lumbox.co)
2. Get API key from dashboard
3. Add to `.env`: `LUMBOX_API_KEY=ak_live_...`

### Pricing

| Plan | Inboxes | Emails/mo | Cost |
|------|---------|-----------|------|
| Free | 3 | 500 | $0 |
| Starter | 10 | 5,000 | $9/mo |
| Pro | 50 | 25,000 | $29/mo |

### How It Works

```javascript
// 1. Create inbox for user (one-time)
const inbox = await createUserVerificationInbox(userId);
// Returns: { email_address: "u_abc123@lumbox.co", lumbox_inbox_id: "inb_xyz" }

// 2. Use email for provider signup
// Browser agent enters: u_abc123@lumbox.co

// 3. Wait for verification OTP
const otp = await waitForEmailOTP(userId, { timeout: 60, from: "noreply@walmart.com" });
// Returns: { code: "847291", from: "noreply@walmart.com" }

// 4. Browser agent enters the OTP
```

### API Reference

```
POST /v1/inboxes                    Create inbox
GET  /v1/inboxes/:id/otp            Wait for OTP (long-poll)
GET  /v1/inboxes/:id/wait           Wait for any email
GET  /v1/inboxes/:id/emails         List emails
POST /v1/inboxes/:id/send           Send from inbox
```

---

## Phone Verification: AgentSIM

**What it does:** Provisions real mobile phone numbers (T-Mobile, AT&T, Verizon) that pass carrier verification checks.

**Why we need it:** Major services (Walmart, Amazon, Stripe, Google) block VoIP numbers like Twilio. They check the number's `line_type` via carrier lookups. AgentSIM provides real SIM-backed numbers that pass these checks.

### The VoIP Problem

| Provider | VoIP Success Rate | Real SIM Success Rate |
|----------|-------------------|----------------------|
| Twilio | 0% | N/A |
| Google Voice | 0% | N/A |
| AgentSIM | N/A | 98-100% |

Platforms detect VoIP numbers in <2 seconds using:
- LERG lookups
- NPAC queries
- HLR checks
- Behavioral analysis

### Setup

1. Sign up at [console.agentsim.dev](https://console.agentsim.dev)
2. Create API key (starts with `asm_live_`)
3. Add to `.env`: `AGENTSIM_API_KEY=asm_live_...`

### Pricing

- **$0.99 per verification session**
- **10 free sessions per month**
- No monthly subscription

### How It Works

```javascript
// 1. Provision a number for verification
const phone = await provisionPhoneForVerification(userId);
// Returns: { number: "+1234567890", id: "num_xyz" }

// 2. Browser agent enters the number on provider signup
// Provider sends SMS to +1234567890

// 3. Wait for OTP
const otp = await waitForSmsOTP(phone.id, { timeout: 60 });
// Returns: { otp_code: "123456" }

// 4. Browser agent enters the OTP

// 5. Release the number when done
await releasePhone(phone.id);
```

### API Reference

```
POST /v1/numbers/provision          Get a number
GET  /v1/numbers/:id/otp            Wait for OTP
POST /v1/numbers/:id/release        Release number
```

---

## User Flow: Creating a Provider Account

```
User taps "Order from Walmart" (first time)
    │
    ▼
Check if user has Walmart account in user_provider_accounts
    │
    ├─ YES → Use existing browser_profile_id
    │
    └─ NO → Create new account:
            │
            ▼
        1. Create Lumbox inbox for user
           Email: u_{user_id}@ounje.lumbox.co
            │
            ▼
        2. Provision AgentSIM phone number
           Phone: +1234567890
            │
            ▼
        3. Browser agent navigates to walmart.com/signup
            │
            ▼
        4. Agent fills form:
           - Email: u_{user_id}@ounje.lumbox.co
           - Password: (generated, stored in vault)
           - Phone: +1234567890
           - Name: from user profile
            │
            ▼
        5. Email verification:
           - Wait for OTP via Lumbox
           - Agent enters code
            │
            ▼
        6. Phone verification:
           - Wait for OTP via AgentSIM
           - Agent enters code
            │
            ▼
        7. Save browser profile (cookies, session)
            │
            ▼
        8. Store in user_provider_accounts:
           - provider_email
           - browser_profile_id
           - login_status: "logged_in"
            │
            ▼
        9. Release AgentSIM phone number
```

---

## Credential Storage

User credentials for provider accounts are stored securely:

1. **Browser Profiles** (browser-use): Persisted session cookies, localStorage
2. **Lumbox Credential Vault**: Encrypted password storage (never returned to agents)
3. **Supabase**: Account metadata (email, profile_id, NOT passwords)

### Security Model

- Passwords are generated by the system, not provided by users
- Passwords are stored in Lumbox vault with AES-256-GCM encryption
- Browser agents use `use_credential_in_browser` to fill forms (credentials never exposed to LLM)
- Users don't need to know or manage provider passwords

---

## Database Schema

```sql
-- User's email inbox for all provider verifications
CREATE TABLE user_verification_inboxes (
  id UUID PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id),
  lumbox_inbox_id TEXT NOT NULL,
  email_address TEXT NOT NULL,  -- e.g., u_abc123@ounje.lumbox.co
  created_at TIMESTAMPTZ DEFAULT now()
);

-- User's accounts on grocery providers
CREATE TABLE user_provider_accounts (
  id UUID PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id),
  provider grocery_provider NOT NULL,
  provider_email TEXT NOT NULL,
  browser_profile_id TEXT,  -- browser-use profile for session persistence
  login_status TEXT DEFAULT 'unknown',
  last_used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

---

## Cost Analysis

For a user creating accounts on 3 providers:

| Service | Cost |
|---------|------|
| Lumbox (1 inbox) | ~$0.30/user/mo (Starter plan) |
| AgentSIM (3 verifications) | $2.97 one-time |
| **Total** | ~$3.27 per user |

After accounts are created, ongoing costs are minimal (just browser-use for ordering).

---

## Implementation Status

- [x] Lumbox integration in `grocery-orchestrator.js`
- [x] AgentSIM integration in `grocery-orchestrator.js`
- [x] Database schema in `20260402_grocery_ordering.sql`
- [ ] Account creation flow in browser-agent
- [ ] Credential vault integration
- [ ] iOS UI for account management

---

## Environment Variables

```bash
# Required for verification
LUMBOX_API_KEY=ak_live_...
AGENTSIM_API_KEY=asm_live_...

# Required for browser automation
BROWSER_USE_API_KEY=bu_...
```

---

## Next Steps

1. **Sign up for Lumbox** at lumbox.co ($9/mo Starter plan)
2. **Sign up for AgentSIM** at agentsim.dev (10 free sessions)
3. **Test the flow** with a single provider (Walmart recommended)
4. **Build iOS UI** for account status and management
