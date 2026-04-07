import http from "node:http";

const port = 8080;
const apiKey = process.env.OPENAI_API_KEY;

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
};

const agentBriefPrompt = `You are writing the operating brief for an agentic meal-prep app called Ounje.

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
- This brief is shown inside the app, so avoid markdown and avoid generic filler.
- Make it feel more vivid and specific than a deterministic template.`;

function sendJSON(response, statusCode, body) {
  response.writeHead(statusCode, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  });
  response.end(JSON.stringify(body));
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.on("data", (chunk) => {
      body += chunk;
    });
    request.on("end", () => {
      resolve(body);
    });
    request.on("error", reject);
  });
}

function normalizeBrief(brief, fallbackBrief) {
  const headline = typeof brief?.headline === "string" && brief.headline.trim().length > 0
    ? brief.headline.trim()
    : fallbackBrief?.headline ?? "Agent brief";

  const narrative = typeof brief?.narrative === "string" && brief.narrative.trim().length > 0
    ? brief.narrative.trim()
    : fallbackBrief?.narrative ?? "Ounje is using your current profile to shape the first planning run.";

  const signals = Array.isArray(brief?.signals)
    ? brief.signals.map((item) => String(item).trim()).filter(Boolean).slice(0, 6)
    : (fallbackBrief?.signals ?? []);

  const graphItems = Array.isArray(brief?.graph_items)
    ? brief.graph_items
        .map((item) => ({
          label: String(item?.label ?? "").trim(),
          value: Math.max(0, Math.min(100, Number(item?.value ?? 0) || 0)),
          caption: String(item?.caption ?? "").trim(),
        }))
        .filter((item) => item.label && item.caption)
        .slice(0, 4)
    : (fallbackBrief?.graph_items ?? []);

  const readinessNotes = Array.isArray(brief?.readiness_notes)
    ? brief.readiness_notes.map((item) => String(item).trim()).filter(Boolean).slice(0, 4)
    : (fallbackBrief?.readiness_notes ?? []);

  return {
    headline,
    narrative,
    visual_tone: typeof brief?.visual_tone === "string" ? brief.visual_tone : (fallbackBrief?.visual_tone ?? "ounje_core"),
    signals,
    graph_items: graphItems,
    readiness_notes: readinessNotes,
  };
}

async function callOpenAI(payload) {
  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify(payload),
  });

  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(JSON.stringify(data));
  }

  return data;
}

const server = http.createServer(async (request, response) => {
  if (request.method === "OPTIONS") {
    response.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
    });
    response.end();
    return;
  }

  if (request.method !== "POST") {
    sendJSON(response, 405, { error: "Method not allowed." });
    return;
  }

  if (!apiKey) {
    sendJSON(response, 500, { error: "OPENAI_API_KEY is not configured for the local inference server." });
    return;
  }

  try {
    const rawBody = await readBody(request);
    const body = rawBody ? JSON.parse(rawBody) : {};

    if (request.url === "/agent-brief") {
      const { profile, summary_sections: summarySections = [], fallback_brief: fallbackBrief } = body;

      if (!profile || !fallbackBrief) {
        sendJSON(response, 400, { error: "Missing required profile payload." });
        return;
      }

      const completion = await callOpenAI({
        model: "gpt-4.1-mini",
        temperature: 0.85,
        response_format: {
          type: "json_schema",
          json_schema: {
            name: "agent_brief",
            strict: true,
            schema: briefSchema,
          },
        },
        messages: [
          { role: "system", content: agentBriefPrompt },
          {
            role: "user",
            content: JSON.stringify(
              {
                profile,
                summary_sections: summarySections,
                fallback_brief: fallbackBrief,
              },
              null,
              2
            ),
          },
        ],
      });

      const content = completion?.choices?.[0]?.message?.content;
      if (typeof content !== "string") {
        sendJSON(response, 502, { error: "The model returned no brief content." });
        return;
      }

      const parsed = JSON.parse(content);
      sendJSON(response, 200, normalizeBrief(parsed, fallbackBrief));
      return;
    }

    const { prompt, images = [] } = body;
    const completion = await callOpenAI({
      model: "gpt-4o",
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: prompt },
            ...images.map((img) => ({
              type: "image_url",
              image_url: { url: `data:image/jpeg;base64,${img}` },
            })),
          ],
        },
      ],
      max_tokens: 600,
    });

    sendJSON(response, 200, { result: completion?.choices?.[0]?.message?.content ?? "" });
  } catch (error) {
    console.error("Local inference server error:", error);
    sendJSON(response, 500, { error: "Local inference server failed." });
  }
});

const host = process.env.HOST || "0.0.0.0";

server.listen(port, host, () => {
  console.log(`Server listening at http://${host}:${port}`);
});
