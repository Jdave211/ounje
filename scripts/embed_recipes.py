#!/usr/bin/env python3
"""
Step 2 — Recipe Embedding Pass
================================
Generates two embeddings per recipe (runs AFTER enrich_recipes.py):

  embedding_basic  (1536-d, text-embedding-3-small)
    Input: title | recipe_type | cuisine_tags | dietary_tags |
           flavor_tags | main_protein | cook_method | occasion_tags

  embedding_rich   (3072-d, text-embedding-3-large)
    Input: full document — title, description, cuisine, occasion,
           skill level, cook time, macros, dietary flags, flavor profile,
           ingredients_text, instructions_text, image_caption

Embeddings are written back via PATCH on the recipes table.
Re-runs are safe — only rows where embeddings_generated_at IS NULL
(or enriched_at > embeddings_generated_at) are processed.
"""

import os, json, time, requests
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed

# ── Config ────────────────────────────────────────────────────────────────────
SUPABASE_URL    = "https://ztqptjimmcdoriefkqcx.supabase.co"
ANON_KEY        = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp0cXB0amltbWNkb3JpZWZrcWN4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM2ODU3NDMsImV4cCI6MjA4OTI2MTc0M30.DncVXO-eWJDKlwQvceSHq4HYV-PuqSqlF8TbWVRZkLA"
OPENAI_KEY      = os.environ["OPENAI_API_KEY"]

MODEL_BASIC     = "text-embedding-3-small"  # → vector(1536)
MODEL_RICH      = "text-embedding-3-large"  # → vector(3072)

EMBED_BATCH     = 100   # recipes per OpenAI batch call (API limit: 2048)
WRITE_WORKERS   = 8     # concurrent Supabase PATCH calls
PAGE_SIZE       = 500
RETRY_LIMIT     = 3

HEADERS_SB  = {"apikey": ANON_KEY, "Authorization": f"Bearer {ANON_KEY}",
               "Content-Type": "application/json", "Prefer": "return=minimal"}
HEADERS_OAI = {"Authorization": f"Bearer {OPENAI_KEY}",
               "Content-Type": "application/json"}

# ── Text builders ─────────────────────────────────────────────────────────────
def arr(val) -> str:
    if not val: return ""
    if isinstance(val, list): return ", ".join(str(v) for v in val)
    return str(val)

def basic_text(r: dict) -> str:
    """~40-70 tokens. Fast retrieval, filter-aware."""
    parts = [
        r.get("title", ""),
        r.get("recipe_type", ""),
        arr(r.get("cuisine_tags")),
        arr(r.get("dietary_tags")),
        arr(r.get("flavor_tags")),
        r.get("main_protein") or "",
        arr(r.get("cook_method")),
        arr(r.get("occasion_tags")),
        r.get("skill_level") or "",
    ]
    return " | ".join(p for p in parts if p)

def rich_text(r: dict) -> str:
    """~300-600 tokens. Deep semantic understanding."""
    lines = [
        f"Title: {r.get('title', '')}",
        f"Description: {r.get('description', '')}",
        f"Cuisine: {arr(r.get('cuisine_tags'))}",
        f"Type: {r.get('recipe_type','')}  Occasion: {arr(r.get('occasion_tags'))}",
        f"Skill: {r.get('skill_level','')}  Cook time: {r.get('cook_time_minutes') or r.get('cook_time_text','')} mins",
        f"Prep: {r.get('prep_time_minutes', '')} mins",
        f"Servings: {r.get('servings_text','')}",
        f"Calories: {r.get('calories_kcal') or r.get('est_calories_text','')} kcal",
        f"Protein: {r.get('protein_g') or r.get('protein_text','')}g  "
        f"Carbs: {r.get('carbs_g') or r.get('carbs_text','')}g  "
        f"Fat: {r.get('fat_g') or r.get('fats_text','')}g",
        f"Dietary: {arr(r.get('dietary_tags'))}",
        f"Main protein: {r.get('main_protein','')}",
        f"Cook method: {arr(r.get('cook_method'))}",
        f"Flavor: {arr(r.get('flavor_tags'))}",
        f"Ingredients: {r.get('ingredients_text','') or ''}",
        f"Instructions: {r.get('instructions_text','') or ''}",
        f"Image: {r.get('image_caption','') or ''}",
        f"Source: {r.get('source_platform','')}",
    ]
    return "\n".join(l for l in lines if l.split(":", 1)[-1].strip())

# ── OpenAI embedding call ─────────────────────────────────────────────────────
def get_embeddings(texts: list[str], model: str) -> list[list[float]] | None:
    for attempt in range(RETRY_LIMIT):
        try:
            resp = requests.post(
                "https://api.openai.com/v1/embeddings",
                headers=HEADERS_OAI,
                json={"model": model, "input": texts, "encoding_format": "float"},
                timeout=60
            )
            resp.raise_for_status()
            data = resp.json()["data"]
            # data is sorted by index
            return [d["embedding"] for d in sorted(data, key=lambda x: x["index"])]
        except Exception as e:
            if attempt < RETRY_LIMIT - 1:
                time.sleep(2 ** attempt)
            else:
                print(f"  ❌ Embedding call failed ({model}): {e}")
                return None

# ── Supabase write ────────────────────────────────────────────────────────────
def patch_embeddings(recipe_id: str, emb_basic: list[float], emb_rich: list[float]) -> bool:
    now = datetime.now(timezone.utc).isoformat()
    payload = {
        "embedding_basic":          emb_basic,
        "embedding_rich":           emb_rich,
        "embeddings_generated_at":  now,
    }

    for attempt in range(RETRY_LIMIT):
        try:
            resp = requests.patch(
                f"{SUPABASE_URL}/rest/v1/recipes?id=eq.{recipe_id}",
                headers=HEADERS_SB,
                json=payload,
                timeout=30
            )
            return resp.status_code in (200, 204)
        except Exception as e:
            if attempt < RETRY_LIMIT - 1:
                time.sleep(2 ** attempt)
            else:
                print(f"  ❌ Supabase write failed for {recipe_id}: {e}")
                return False

# ── Fetch helpers ─────────────────────────────────────────────────────────────
FETCH_COLS = (
    "id,title,description,recipe_type,skill_level,cook_time_text,"
    "cook_time_minutes,prep_time_minutes,servings_text,"
    "est_calories_text,carbs_text,protein_text,fats_text,"
    "calories_kcal,protein_g,carbs_g,fat_g,"
    "cuisine_tags,dietary_tags,flavor_tags,main_protein,"
    "cook_method,occasion_tags,"
    "ingredients_text,instructions_text,image_caption,"
    "source_platform,enriched_at,embeddings_generated_at"
)

def fetch_page() -> list[dict]:
    """Fetch recipes that need (re-)embedding:
       enriched_at IS NOT NULL AND
       (embeddings_generated_at IS NULL OR embeddings_generated_at < enriched_at)
    """
    # Supabase doesn't support column comparisons in query params directly,
    # so we fetch enriched rows and filter client-side for the stale check.
    r = requests.get(
        f"{SUPABASE_URL}/rest/v1/recipes",
        params={
            "select":           FETCH_COLS,
            "enriched_at":      "not.is.null",
            "embedding_basic":  "is.null",   # not yet embedded
            "limit":            PAGE_SIZE,
            "order":            "created_at.asc",
        },
        headers={"apikey": ANON_KEY, "Authorization": f"Bearer {ANON_KEY}"},
        timeout=30
    )
    return r.json() if r.ok else []

def fetch_stale_page() -> list[dict]:
    r = requests.get(
        f"{SUPABASE_URL}/rest/v1/recipes",
        params={
            "select":          FETCH_COLS,
            "enriched_at":     "not.is.null",
            "embedding_basic": "not.is.null",
            "limit":           PAGE_SIZE,
            "order":           "enriched_at.desc",
        },
        headers={"apikey": ANON_KEY, "Authorization": f"Bearer {ANON_KEY}"},
        timeout=30
    )
    return r.json() if r.ok else []

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("=" * 60)
    print("Ounje Recipe Embedding Pass")
    print("=" * 60)

    total_done = 0
    total_failed = 0
    while True:
        page = fetch_page()
        if not page:
            break

        print(f"\n📦 Embedding batch, {len(page)} recipes...")

        # Chunk into EMBED_BATCH-sized groups for OpenAI batch call
        for chunk_start in range(0, len(page), EMBED_BATCH):
            chunk = page[chunk_start: chunk_start + EMBED_BATCH]

            basic_inputs = [basic_text(r) for r in chunk]
            rich_inputs  = [rich_text(r)  for r in chunk]

            # Embed both tiers in parallel
            with ThreadPoolExecutor(max_workers=2) as pool:
                fut_basic = pool.submit(get_embeddings, basic_inputs, MODEL_BASIC)
                fut_rich  = pool.submit(get_embeddings, rich_inputs,  MODEL_RICH)
                basics = fut_basic.result()
                riches = fut_rich.result()

            if basics is None or riches is None:
                print(f"  ❌ Skipping chunk (embedding call failed)")
                total_failed += len(chunk)
                continue

            # Write back concurrently
            def write(i):
                return patch_embeddings(chunk[i]["id"], basics[i], riches[i])

            with ThreadPoolExecutor(max_workers=WRITE_WORKERS) as pool:
                results = list(pool.map(write, range(len(chunk))))

            done = sum(results)
            total_done += done
            total_failed += len(chunk) - done
            print(f"  ✅ {done}/{len(chunk)} written (running total: {total_done})")

    # ── Also handle stale embeddings (enriched AFTER last embedding) ──────────
    print(f"\n🔄 Checking for stale embeddings (enriched_at > embeddings_generated_at)...")
    while True:
        stale_page = fetch_stale_page()
        stale = [
            row for row in stale_page
            if row.get("enriched_at") and row.get("embeddings_generated_at")
            and row["enriched_at"] > row["embeddings_generated_at"]
        ]
        if not stale:
            break

        print(f"  Found {len(stale)} stale rows, re-embedding...")
        for chunk_start in range(0, len(stale), EMBED_BATCH):
            chunk = stale[chunk_start: chunk_start + EMBED_BATCH]
            basics = get_embeddings([basic_text(r) for r in chunk], MODEL_BASIC)
            riches = get_embeddings([rich_text(r)  for r in chunk], MODEL_RICH)
            if basics and riches:
                for i, row in enumerate(chunk):
                    patch_embeddings(row["id"], basics[i], riches[i])
                total_done += len(chunk)

        if len(stale_page) < PAGE_SIZE and not stale:
            break
        if not stale:
            break

    print(f"\n{'=' * 60}")
    print(f"✅ Embedding complete: {total_done} succeeded, {total_failed} failed")
    print(f"{'=' * 60}")
    print("→ Now add HNSW indexes via the Supabase dashboard:")
    print("  CREATE INDEX ON recipes USING hnsw(embedding_basic vector_cosine_ops);")
    print("  CREATE INDEX ON recipes USING hnsw(embedding_rich  vector_cosine_ops);")

if __name__ == "__main__":
    main()
