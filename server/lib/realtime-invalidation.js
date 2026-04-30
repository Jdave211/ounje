const SUPABASE_URL = process.env.SUPABASE_URL ?? "";
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? "";

function normalizeText(value) {
  return String(value ?? "").trim();
}

export function realtimeUserTopic(userId) {
  const normalizedUserId = normalizeText(userId);
  return normalizedUserId ? `ounje:user:${normalizedUserId}` : null;
}

export async function broadcastUserInvalidation(userId, event, payload = {}) {
  const topic = realtimeUserTopic(userId);
  const eventName = normalizeText(event);
  const realtimeKey = SUPABASE_SERVICE_ROLE_KEY || SUPABASE_ANON_KEY;
  if (!SUPABASE_URL || !realtimeKey || !topic || !eventName) {
    return false;
  }

  try {
    const response = await fetch(`${SUPABASE_URL.replace(/\/+$/, "")}/realtime/v1/api/broadcast`, {
      method: "POST",
      headers: {
        apikey: realtimeKey,
        Authorization: `Bearer ${realtimeKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        messages: [
          {
            topic,
            event: eventName,
            payload: {
              ...(payload && typeof payload === "object" ? payload : {}),
              user_id: normalizeText(userId),
              emitted_at: new Date().toISOString(),
            },
          },
        ],
      }),
    });

    if (!response.ok) {
      const message = await response.text().catch(() => "");
      console.warn?.(`[realtime] broadcast ${eventName} failed (${response.status}): ${message.slice(0, 180)}`);
      return false;
    }

    return true;
  } catch (error) {
    console.warn?.(`[realtime] broadcast ${eventName} failed: ${error.message}`);
    return false;
  }
}
