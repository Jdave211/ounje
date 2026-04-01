#!/usr/bin/env python3
import json
import os
from pathlib import Path

import psycopg


ROOT = Path("/Users/davejaga/Desktop/startups/ounje")
CACHE_PATH = ROOT / "server/data/discover/discover_brackets.json"
MIGRATION_PATH = ROOT / "supabase/migrations/20260329_recipe_discover_brackets.sql"


def main():
    database_url = os.getenv("DATABASE_URL", "").strip()
    if not database_url:
      raise RuntimeError("DATABASE_URL is required")

    cache = json.loads(CACHE_PATH.read_text())
    by_recipe_id = cache.get("by_recipe_id", {})
    rows = [
        (
            recipe_id,
            sorted(set(payload.get("brackets", []))),
            cache.get("generated_at"),
        )
        for recipe_id, payload in by_recipe_id.items()
    ]

    migration_sql = MIGRATION_PATH.read_text()

    with psycopg.connect(database_url) as conn:
        with conn.cursor() as cur:
            cur.execute(migration_sql)
            cur.executemany(
                """
                UPDATE public.recipes
                SET discover_brackets = %s::text[],
                    discover_brackets_enriched_at = COALESCE(%s::timestamptz, now())
                WHERE id = %s::uuid
                """,
                [(brackets, enriched_at, recipe_id) for recipe_id, brackets, enriched_at in rows],
            )
        conn.commit()

        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                  COUNT(*) FILTER (WHERE COALESCE(array_length(discover_brackets, 1), 0) = 0) AS missing_brackets,
                  COUNT(*) FILTER (WHERE discover_brackets_enriched_at IS NULL) AS missing_enriched_at,
                  COUNT(*) AS total
                FROM public.recipes
                """
            )
            missing_brackets, missing_enriched_at, total = cur.fetchone()

            cur.execute(
                """
                SELECT bracket, COUNT(*)
                FROM (
                  SELECT unnest(discover_brackets) AS bracket
                  FROM public.recipes
                ) s
                GROUP BY bracket
                ORDER BY COUNT(*) DESC, bracket ASC
                """
            )
            bracket_counts = cur.fetchall()

    print(json.dumps({
        "persisted_rows": len(rows),
        "total_recipes": total,
        "missing_brackets": missing_brackets,
        "missing_enriched_at": missing_enriched_at,
        "bracket_counts": [
            {"bracket": bracket, "count": count}
            for bracket, count in bracket_counts
        ],
    }, indent=2))


if __name__ == "__main__":
    main()
