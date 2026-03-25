const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

const briefSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    headline: { type: "string" },
    narrative: { type: "string" },
    visual_tone: {
      type: "string",
      enum: ["night_heat", "clean_grid", "control_mode", "neon_pantry", "ounje_core"],
    },
    signals: {
      type: "array",
      items: { type: "string" },
      minItems: 3,
      maxItems: 6,
    },
    graph_items: {
      type: "array",
      minItems: 3,
      maxItems: 4,
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          label: { type: "string" },
          value: { type: "integer", minimum: 0, maximum: 100 },
          caption: { type: "string" },
        },
        required: ["label", "value", "caption"],
      },
    },
    readiness_notes: {
      type: "array",
      items: { type: "string" },
      minItems: 3,
      maxItems: 4,
    },
  },
  required: ["headline", "narrative", "visual_tone", "signals", "graph_items", "readiness_notes"],
} as const

const systemPrompt = `You are writing the operating brief for an agentic meal-prep app called Ounje.

Return a concise, high-signal planning brief derived only from the supplied onboarding profile.

Rules:
- Do not invent allergies, cuisines, budget room, autonomy level, or household context.
- Keep the tone sharp, modern, and direct.
- Headline: 4 to 9 words, no trailing punctuation.
- Narrative: exactly one sentence.
- Visual tone: choose exactly one of night_heat, clean_grid, control_mode, neon_pantry, ounje_core.
- Signals: 3 to 6 short labels, each 1 to 4 words.
- Graph items: return 3 to 4 compact metrics with label, 0-100 value, and a short caption.
- Readiness notes: 3 to 4 short sentences describing what the planner will optimize around, what it must avoid, and how it will operate.
- If information is missing, acknowledge the gap without sounding robotic.
- This brief is shown inside the app, so avoid buzzwords and avoid markdown.`

type Brief = {
  headline?: string
  narrative?: string
  visual_tone?: string
  signals?: string[]
  graph_items?: Array<{ label?: string; value?: number; caption?: string }>
  readiness_notes?: string[]
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  })
}

function cleanLines(values: unknown, fallback: string[], maxCount: number) {
  if (!Array.isArray(values)) {
    return fallback.slice(0, maxCount)
  }

  const cleaned = values
    .map((value) => (typeof value === "string" ? value.trim() : ""))
    .filter(Boolean)

  return Array.from(new Set(cleaned)).slice(0, maxCount)
}

function cleanText(value: unknown, fallback: string) {
  if (typeof value !== "string") {
    return fallback
  }

  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : fallback
}

function normalizeBrief(brief: Brief, fallback: Brief) {
  return {
    headline: cleanText(brief.headline, fallback.headline ?? "Agent brief"),
    narrative: cleanText(brief.narrative, fallback.narrative ?? "Ounje is using your current profile to shape the first planning run."),
    visual_tone: cleanText(brief.visual_tone, fallback.visual_tone ?? "ounje_core"),
    signals: cleanLines(brief.signals, fallback.signals ?? [], 6),
    graph_items: Array.isArray(brief.graph_items)
      ? brief.graph_items
          .map((item) => ({
            label: cleanText(item?.label, ""),
            value: Math.max(0, Math.min(100, Number(item?.value ?? 0) || 0)),
            caption: cleanText(item?.caption, ""),
          }))
          .filter((item) => item.label.length > 0 && item.caption.length > 0)
          .slice(0, 4)
      : (fallback.graph_items ?? []),
    readiness_notes: cleanLines(brief.readiness_notes, fallback.readiness_notes ?? [], 4),
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405)
  }

  const openAIKey = Deno.env.get("OPENAI_API_KEY")
  if (!openAIKey) {
    return jsonResponse({ error: "OPENAI_API_KEY is not configured for the agent-brief function." }, 500)
  }

  let payload: Record<string, unknown>
  try {
    payload = await request.json()
  } catch {
    return jsonResponse({ error: "Invalid JSON body." }, 400)
  }

  const fallbackBrief = payload.fallback_brief as Brief | undefined
  const profile = payload.profile
  const summarySections = payload.summary_sections

  if (!profile || !fallbackBrief) {
    return jsonResponse({ error: "Missing required profile payload." }, 400)
  }

  const openAIResponse = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${openAIKey}`,
    },
    body: JSON.stringify({
      model: "gpt-4.1-mini",
      temperature: 0.8,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "agent_brief",
          strict: true,
          schema: briefSchema,
        },
      },
      messages: [
        {
          role: "system",
          content: systemPrompt,
        },
        {
          role: "user",
          content: JSON.stringify(
            {
              profile,
              summary_sections: summarySections,
              fallback_brief: fallbackBrief,
            },
            null,
            2,
          ),
        },
      ],
    }),
  })

  if (!openAIResponse.ok) {
    const errorBody = await openAIResponse.text()
    console.error("agent-brief openai error", errorBody)
    return jsonResponse({ error: "OpenAI brief inference failed." }, 502)
  }

  const completion = await openAIResponse.json()
  const content = completion?.choices?.[0]?.message?.content

  if (typeof content !== "string") {
    return jsonResponse({ error: "The model returned no brief content." }, 502)
  }

  try {
    const parsed = JSON.parse(content) as Brief
    return jsonResponse(normalizeBrief(parsed, fallbackBrief))
  } catch (error) {
    console.error("agent-brief parse error", error)
    return jsonResponse(normalizeBrief({}, fallbackBrief))
  }
})
