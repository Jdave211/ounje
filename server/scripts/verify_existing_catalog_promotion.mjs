#!/usr/bin/env node

import { readFile } from "node:fs/promises";

import dotenv from "dotenv";
import pg from "pg";

dotenv.config({ path: "server/.env" });

function hasSocialSource(row) {
  return [row.recipe_url, row.original_recipe_url, row.attached_video_url].some((value) => {
    try {
      const host = new URL(value).hostname.toLowerCase();
      return host.includes("tiktok.com") || host.includes("instagram.com");
    } catch {
      return false;
    }
  });
}

const poolerURL = new URL((await readFile("supabase/.temp/pooler-url", "utf8")).trim());
const client = new pg.Client({
  host: poolerURL.hostname,
  port: Number(poolerURL.port),
  database: poolerURL.pathname.slice(1),
  user: decodeURIComponent(poolerURL.username),
  password: process.env.SUPABASE_DB_PASSWORD,
  ssl: { rejectUnauthorized: false },
});

await client.connect();
try {
  const recipes = await client.query(`
    SELECT
      r.id,
      r.title,
      r.hero_image_url,
      r.discover_card_image_url,
      r.recipe_url,
      r.original_recipe_url,
      r.attached_video_url,
      count(DISTINCT i.id)::integer AS ingredients,
      count(DISTINCT s.id)::integer AS steps
    FROM public.recipes r
    LEFT JOIN public.recipe_ingredients i ON i.recipe_id = r.id
    LEFT JOIN public.recipe_steps s ON s.recipe_id = r.id
    WHERE r.source_provenance_json @> '{"catalog_origin":"existing_import"}'::jsonb
    GROUP BY r.id
  `);
  const jobs = await client.query(`
    SELECT status, worker_id, request_payload, recipe_id
    FROM public.recipe_ingestion_jobs
    WHERE user_id IS NULL
      AND request_payload @> '{"public_catalog_import":true}'::jsonb
  `);
  const activeVMLeases = await client.query(`
    SELECT count(*)::integer AS count
    FROM public.recipe_ingestion_jobs
    WHERE worker_id LIKE 'vm_recipe_ingest%'
      AND status IN ('processing', 'fetching', 'parsing', 'normalized')
  `);
  const vmClaim = await client.query(
    "SELECT count(*)::integer AS count FROM public.claim_recipe_ingestion_jobs($1, $2)",
    ["vm_recipe_ingest_final_verification", 1]
  );
  const migration = await client.query(
    "SELECT count(*)::integer AS count FROM supabase_migrations.schema_migrations WHERE version = $1",
    ["20260822030626"]
  );

  console.log(JSON.stringify({
    catalog_recipes: recipes.rowCount,
    all_have_titles: recipes.rows.every((row) => String(row.title ?? "").trim()),
    all_have_images: recipes.rows.every((row) => row.hero_image_url || row.discover_card_image_url),
    minimum_ingredients: Math.min(...recipes.rows.map((row) => row.ingredients)),
    minimum_steps: Math.min(...recipes.rows.map((row) => row.steps)),
    all_have_social_source: recipes.rows.every(hasSocialSource),
    catalog_jobs: jobs.rowCount,
    represented_catalog_recipes: new Set(jobs.rows.map((row) => row.recipe_id).filter(Boolean)).size,
    all_jobs_saved: jobs.rows.every((row) => row.status === "saved"),
    active_vm_leases: activeVMLeases.rows[0].count,
    vm_claim_count: vmClaim.rows[0].count,
    retirement_migration_recorded: migration.rows[0].count === 1,
  }, null, 2));
} finally {
  await client.end();
}
