#!/usr/bin/env python3
"""
Step 1 — Recipe Enrichment Pass
================================
Calls GPT-4o-mini (with vision for image captions) on every recipe row
that hasn't been enriched yet, and writes back structured metadata:

  cuisine_tags, dietary_tags, flavor_tags, main_protein, cook_method,
  occasion_tags, prep_time_minutes, cook_time_minutes, calories_kcal,
  protein_g, carbs_g, fat_g, ingredients_text, instructions_text, image_caption

Run AFTER applying the 20260324_recipe_embeddings.sql migration.
Run BEFORE the embed_recipes.py script.
"""

import os, json, time, requests, re
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed

# ── Config ────────────────────────────────────────────────────────────────────
SUPABASE_URL = "https://ztqptjimmcdoriefkqcx.supabase.co"
ANON_KEY     = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp0cXB0amltbWNkb3JpZWZrcWN4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM2ODU3NDMsImV4cCI6MjA4OTI2MTc0M30.DncVXO-eWJDKlwQvceSHq4HYV-PuqSqlF8TbWVRZkLA"
OPENAI_KEY   = os.environ["OPENAI_API_KEY"]
MODEL        = "gpt-4o-mini"
BATCH_SIZE   = 4        # concurrent OpenAI calls (reduced to avoid rate limits)
PAGE_SIZE    = 200      # rows fetched per Supabase page
RETRY_LIMIT  = 4

HEADERS_SB   = {"apikey": ANON_KEY, "Authorization": f"Bearer {ANON_KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"}
HEADERS_OAI  = {"Authorization": f"Bearer {OPENAI_KEY}",
                "Content-Type": "application/json"}

SYSTEM_PROMPT = """\
You are a culinary data enrichment assistant for a recipe app called Ounje,
focused on Nigerian, West African, and international food.

Given a recipe's metadata and hero image URL, return a JSON object with these fields:

{
  "cuisine_tags":       string[],   // e.g. ["Nigerian","West African"] or ["Italian","Mediterranean"]
  "dietary_tags":       string[],   // from: gluten-free, dairy-free, nut-free, vegan, vegetarian, 
                                    //       pescatarian, high-protein, low-carb, keto, paleo, halal, kosher
  "flavor_tags":        string[],   // from: spicy, sweet, savory, smoky, tangy, umami, herby, rich, mild, bitter
  "main_protein":       string|null,// single dominant protein: chicken, beef, fish, shrimp, lamb, pork,
                                    //   tofu, egg, beans, lentils, or null if none
  "cook_method":        string[],   // from: fried, baked, grilled, steamed, boiled, raw, roasted,
                                    //   stovetop, air-fried, slow-cooked, pressure-cooked, blended
  "occasion_tags":      string[],   // from: weeknight, party, meal-prep, holiday, breakfast-on-the-go,
                                    //   date-night, comfort-food, street-food, special-occasion
  "prep_time_minutes":  int|null,
  "cook_time_minutes":  int|null,
  "calories_kcal":      int|null,   // per serving, integer
  "protein_g":          float|null,
  "carbs_g":            float|null,
  "fat_g":              float|null,
  "ingredients_text":   string,     // normalized flat string: "2 cups rice, 1 scotch bonnet, ..."
                                    // infer from description if not explicitly given
  "instructions_text":  string,     // concise step-by-step. Infer from context if not given.
  "image_caption":      string      // 1-2 sentences describing what is visually shown in the image
                                    // if no image, describe the dish from context
}

Rules:
- Always return valid JSON, no markdown.
- Use the image URL to visually describe the dish for image_caption.
- For cuisine_tags: every recipe must have at least 1 tag.
- For Nigerian/African dishes, always include "Nigerian" or relevant country AND "West African" or "African".
- For nutrition: parse from est_calories_text/carbs_text/protein_text/fats_text — extract numbers only.
  If ambiguous or missing, make a reasonable culinary estimate.
- ingredients_text must be a clean comma-separated string, not a list.
- instructions_text: max 8 steps, keep concise.
"""

def call_openai(recipe: dict) -> dict | None:
    """Call GPT-4o-mini with optional image for one recipe."""
    image_url = recipe.get("hero_image_url") or ""

    user_content = [
        {
            "type": "text",
            "text": (
                f"Recipe title: {recipe.get('title','')}\n"
                f"Description: {recipe.get('description','')}\n"
                f"Category: {recipe.get('category','')} / {recipe.get('subcategory','')}\n"
                f"Type: {recipe.get('recipe_type','')}\n"
                f"Skill level: {recipe.get('skill_level','')}\n"
                f"Cook time: {recipe.get('cook_time_text','')}\n"
                f"Servings: {recipe.get('servings_text','')}\n"
                f"Calories: {recipe.get('est_calories_text','')}\n"
                f"Carbs: {recipe.get('carbs_text','')}\n"
                f"Protein: {recipe.get('protein_text','')}\n"
                f"Fat: {recipe.get('fats_text','')}\n"
                f"Source: {recipe.get('source_platform','')}\n"
            )
        }
    ]

    # Attach image if available (skip Firebase URLs which may have auth tokens)
    if image_url and "supabase.co" in image_url:
        user_content.append({
            "type": "image_url",
            "image_url": {"url": image_url, "detail": "low"}
        })
    elif image_url:
        # For external images, add URL as text so model can describe based on context
        user_content[0]["text"] += f"Image URL: {image_url}\n"

    for attempt in range(RETRY_LIMIT):
        try:
            resp = requests.post(
                "https://api.openai.com/v1/chat/completions",
                headers=HEADERS_OAI,
                json={
                    "model": MODEL,
                    "messages": [
                        {"role": "system", "content": SYSTEM_PROMPT},
                        {"role": "user",   "content": user_content}
                    ],
                    "temperature": 0.2,
                    "max_tokens": 800,
                    "response_format": {"type": "json_object"}
                },
                timeout=30
            )
            resp.raise_for_status()
            raw = resp.json()["choices"][0]["message"]["content"]
            return json.loads(raw)
        except Exception as e:
            err = str(e)
            wait = 2 ** attempt
            if "rate_limit" in err.lower() or "429" in err:
                wait = 30 + 2 ** attempt  # longer wait on rate limit
            if attempt < RETRY_LIMIT - 1:
                time.sleep(wait)
            else:
                print(f"  ❌ OpenAI failed for {recipe.get('id')}: {e}")
                return None

def safe_int(val) -> int | None:
    if val is None: return None
    try: return int(round(float(str(val).replace(',',''))))
    except: return None

def safe_float(val) -> float | None:
    if val is None: return None
    try:
        s = re.sub(r'[^\d.]', '', str(val).split()[0])
        return float(s) if s else None
    except: return None

def patch_recipe(recipe_id: str, enriched: dict):
    now = datetime.now(timezone.utc).isoformat()
    payload = {
        "cuisine_tags":      enriched.get("cuisine_tags") or [],
        "dietary_tags":      enriched.get("dietary_tags") or [],
        "flavor_tags":       enriched.get("flavor_tags") or [],
        "main_protein":      enriched.get("main_protein"),
        "cook_method":       enriched.get("cook_method") or [],
        "occasion_tags":     enriched.get("occasion_tags") or [],
        "prep_time_minutes": safe_int(enriched.get("prep_time_minutes")),
        "cook_time_minutes": safe_int(enriched.get("cook_time_minutes")),
        "calories_kcal":     safe_int(enriched.get("calories_kcal")),
        "protein_g":         safe_float(enriched.get("protein_g")),
        "carbs_g":           safe_float(enriched.get("carbs_g")),
        "fat_g":             safe_float(enriched.get("fat_g")),
        "ingredients_text":  enriched.get("ingredients_text") or "",
        "instructions_text": enriched.get("instructions_text") or "",
        "image_caption":     enriched.get("image_caption") or "",
        "enriched_at":       now,
    }
    # Remove None values to avoid overwriting with null
    payload = {k: v for k, v in payload.items() if v is not None or k in (
        "main_protein", "prep_time_minutes", "cook_time_minutes",
        "calories_kcal", "protein_g", "carbs_g", "fat_g"
    )}
    r = requests.patch(
        f"{SUPABASE_URL}/rest/v1/recipes?id=eq.{recipe_id}",
        headers=HEADERS_SB,
        json=payload,
        timeout=15
    )
    return r.status_code in (200, 204)

def process_recipe(recipe: dict) -> tuple[str, bool]:
    enriched = call_openai(recipe)
    if not enriched:
        return recipe["id"], False
    ok = patch_recipe(recipe["id"], enriched)
    return recipe["id"], ok

def fetch_unenriched_page() -> list[dict]:
    cols = "id,title,description,category,subcategory,recipe_type,skill_level,cook_time_text,servings_text,est_calories_text,carbs_text,protein_text,fats_text,source_platform,hero_image_url"
    r = requests.get(
        f"{SUPABASE_URL}/rest/v1/recipes",
        params={
            "select": cols,
            "enriched_at": "is.null",
            "limit": PAGE_SIZE,
            "order": "created_at.asc"
        },
        headers={"apikey": ANON_KEY, "Authorization": f"Bearer {ANON_KEY}"},
        timeout=30
    )
    return r.json() if r.ok else []

def main():
    print("=" * 60)
    print("Ounje Recipe Enrichment Pass")
    print("=" * 60)

    total_done = 0
    total_failed = 0
    while True:
        page = fetch_unenriched_page()
        if not page:
            break

        print(f"\n📦 Enrichment batch, {len(page)} recipes...")

        with ThreadPoolExecutor(max_workers=BATCH_SIZE) as pool:
            futures = {pool.submit(process_recipe, r): r["id"] for r in page}
            for fut in as_completed(futures):
                rid, ok = fut.result()
                if ok:
                    total_done += 1
                    if total_done % 50 == 0:
                        print(f"  ✅ {total_done} enriched so far...")
                else:
                    total_failed += 1

        time.sleep(1.5)  # pause between pages to respect rate limits

    print(f"\n{'=' * 60}")
    print(f"✅ Enrichment complete: {total_done} succeeded, {total_failed} failed")
    print(f"{'=' * 60}")
    print("→ Now run: python3 scripts/embed_recipes.py")

if __name__ == "__main__":
    main()
