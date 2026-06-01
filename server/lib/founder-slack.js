// Lightweight founder Slack notifications (signup/onboarding, etc.).
// Subscription alerts have their own richer formatter in app-store-notifications.js;
// this is the general-purpose path that reuses the same webhook env.

const FOUNDER_SLACK_TIMEOUT_MS = 5000;

export function resolveFounderSlackWebhookURL() {
  return [
    process.env.OUNJE_FOUNDER_SLACK_WEBHOOK_URL,
    process.env.FOUNDER_SLACK_WEBHOOK_URL,
    process.env.SLACK_WEBHOOK_URL,
  ]
    .map((value) => (typeof value === "string" ? value.trim() : ""))
    .find(Boolean) ?? "";
}

// Posts a simple Slack message. Never throws — returns a {sent, reason} result so
// callers can fire-and-forget without risking the request that triggered it.
export async function sendFounderSlackMessage({ heading, fields = [], context = null } = {}) {
  const webhookURL = resolveFounderSlackWebhookURL();
  if (!webhookURL) return { sent: false, reason: "not_configured" };

  const blocks = [];
  if (heading) {
    blocks.push({ type: "section", text: { type: "mrkdwn", text: String(heading) } });
  }
  const fieldBlocks = (Array.isArray(fields) ? fields : [])
    .filter((field) => field && field.label && field.value != null && String(field.value).trim() !== "")
    .slice(0, 10)
    .map((field) => ({ type: "mrkdwn", text: `*${field.label}:*\n${field.value}` }));
  if (fieldBlocks.length) {
    blocks.push({ type: "section", fields: fieldBlocks });
  }
  if (context) {
    blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: String(context) }] });
  }
  if (!blocks.length) return { sent: false, reason: "empty" };

  try {
    const response = await fetch(webhookURL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ blocks }),
      signal: AbortSignal.timeout(FOUNDER_SLACK_TIMEOUT_MS),
    });
    if (!response.ok) return { sent: false, reason: `http_${response.status}` };
    return { sent: true };
  } catch (error) {
    return { sent: false, reason: error?.message ?? "request_failed" };
  }
}
