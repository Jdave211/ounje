# Growth Outreach Agent

The growth outreach worker finds reviewable Quora and roundup-list opportunities for Ounje. It is intentionally human-in-the-loop:

- It discovers 10-15 relevant Quora questions before drafting answers.
- It drafts Quora answers that answer the question first and disclose affiliation.
- It runs generated answers through a humanizer pass so drafts read less like generic LLM copy.
- It discovers 10-15 relevant roundup posts before drafting inclusion pitches.
- It stores candidates and drafts in Supabase for review.
- It can also run in local artifact mode, writing temp JSON files under `tmp/growth-outreach/`.
- It does not auto-post to Quora, bypass login flows, scrape around bot controls, or send outreach emails.

## Policy Guardrails

Quora's current [Question and Answer Policies](https://help.quora.com/hc/en-us/articles/9456583756180-Question-and-Answer-Policies) require answers to respond to the question, disclose relevant affiliations, and avoid self-promotion that is not directly helpful. Quora's [Platform Policies](https://help.quora.com/hc/en-us/articles/360000470706-Platform-Policies) also treat repeated content, irrelevant answers, and excessive product promotion for traffic as spam.

The worker encodes that as:

- `pending_review` drafts only.
- first-person disclosure such as `I work on Ounje`.
- standalone answers that can be understood without clicking a link.
- medical, allergy, weight-loss, and eating-disorder topic avoidance.
- draft thresholds so it researches a set of opportunities before writing.

## Files

- `server/config/growth-outreach.json` controls Ounje positioning, search queries, and draft thresholds.
- `server/lib/growth-outreach-agent.js` contains discovery, scoring, drafting, and Supabase persistence.
- `server/scripts/growth_outreach_worker.mjs` runs the daemon.
- `server/scripts/queue_growth_outreach_job.mjs` queues one run.
- `server/scripts/run_growth_outreach_local.mjs` runs without Supabase and writes local JSON artifacts.
- `deploy/systemd/ounje-growth-outreach-worker.service` is the production worker unit.
- `supabase/migrations/20260517150934_growth_outreach_agent.sql` creates the review tables.

## Environment

Required:

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`

Recommended:

- `OPENAI_API_KEY` for stronger drafts. Without it, deterministic review drafts are still created.
- One search provider key:
  - `SERPER_API_KEY`
  - `BRAVE_SEARCH_API_KEY`
  - `SERPAPI_API_KEY`
- Optional `GROWTH_SEARCH_PROVIDER=serper|brave|serpapi|browser-use|playwright` to force one provider. If no search API key is configured, the local runner falls back to browser-use when `BROWSER_USE_API_KEY` exists, then Playwright.
- Optional `GROWTH_BROWSER_USE_MODEL` to override the browser-use task model.
- Optional `GROWTH_PLAYWRIGHT_SEARCH_ENGINE=duckduckgo|bing`.
- Optional `GROWTH_SEARCH_HEADED=true` to watch Playwright search in a visible browser.
- Optional `GROWTH_PLAYWRIGHT_USER_DATA_DIR=tmp/growth-outreach/playwright-profile` to reuse a logged-in browser profile.

Optional scheduling:

- `GROWTH_OUTREACH_AUTO_ENQUEUE_USER_ID=<auth.users.id>`
- `GROWTH_OUTREACH_AUTO_ENQUEUE_MODE=both|quora|roundups`
- `GROWTH_OUTREACH_INTERVAL_HOURS=168`

Optional local artifact mode:

- `GROWTH_OUTREACH_STORAGE=local` for DB-queued jobs that should write local files.
- `GROWTH_OUTREACH_LOCAL_DIR=tmp/growth-outreach` to change the output directory.

Optional app/profile overrides:

- `OUNJE_PUBLIC_BASE_URL`
- `OUNJE_APP_DOWNLOAD_URL`
- `GROWTH_OUTREACH_CONTACT_NAME`
- `GROWTH_OUTREACH_CONTACT_EMAIL`
- `GROWTH_OUTREACH_OPENAI_MODEL`

## Commands

Queue one run:

```bash
npm run growth:queue-outreach -- --user-id <auth_user_uuid> --mode both
```

Process one queued job:

```bash
npm run growth:outreach-once
```

Run the daemon:

```bash
npm run growth:outreach-worker
```

Run without the app database:

```bash
npm run growth:outreach-local -- --mode both
```

Open a headed Quora login browser:

```bash
npm run growth:quora-login
```

Google sign-in may reject Playwright-controlled browsers. Use Quora email/password login in the opened browser profile; if the account is Google-only, set a Quora password from a normal browser first.

Run focused tests:

```bash
npm run growth:outreach-test
```

## Review Workflow

Quora:

1. Review `quora_question_candidates` and keep questions Ounje can answer with real expertise.
2. Review `quora_answer_drafts`.
3. Edit for the exact question context.
4. Post manually from the appropriate Quora account.
5. Mark the candidate/draft as `posted`.

Roundups:

1. Review `roundup_list_opportunities`.
2. Find or verify the author and contact path.
3. Review `roundup_pitch_drafts`.
4. Send manually from the founder or company email.
5. Mark the pitch as `sent`, then use follow-up drafts only if appropriate.
