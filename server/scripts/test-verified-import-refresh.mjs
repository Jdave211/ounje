// Generate a rollback-only database integration test using the real artifact builder.
import fs from 'node:fs';
for(const key of ['OPENAI_API_KEY','SUPABASE_URL','SUPABASE_ANON_KEY','SUPABASE_SERVICE_ROLE_KEY'])process.env[key]='';
const {buildUserImportedRecipeArtifacts}=await import('../lib/recipe-ingestion.js');
const artifact=buildUserImportedRecipeArtifacts({id:'uir_refresh_transaction_test',title:'Verified test recipe',ingredients:[{display_name:'flour',quantity_text:'100 g'},{display_name:'milk',quantity_text:'100 ml'},{display_name:'egg',quantity_text:'1'}],steps:[{number:1,text:'Mix flour, milk and egg until smooth.',ingredients:[{display_name:'egg',quantity_text:'1'}]},{number:2,text:'Cook the batter in a hot pan until set.'}],source_provenance_json:{quality_history:{final_completeness_verified:true}},servings_count:2},{userID:'quality-test',sourceJobID:'ri_refresh_transaction_test',dedupeKey:'refresh-test-key',reviewState:'approved',confidenceScore:0.9,qualityFlags:[]});
const sql=`BEGIN;
${fs.readFileSync(new URL('../../supabase/migrations/20260910203014_refresh_verified_imported_recipe.sql',import.meta.url),'utf8')}
DO $test$
DECLARE a jsonb := $json$${JSON.stringify(artifact)}$json$;
        stamp timestamptz;
        result boolean;
BEGIN
  INSERT INTO public.recipe_ingestion_jobs(id,user_id,source_type,dedupe_key,review_state) VALUES ('ri_refresh_transaction_test','quality-test','tiktok','refresh-test-key','approved');
  INSERT INTO public.user_import_recipes(id,user_id,title,dedupe_key,quality_flags,updated_at) VALUES ('uir_refresh_transaction_test','quality-test','Old partial recipe','refresh-test-key',ARRAY['partial_steps'],'2020-01-01');
  SELECT updated_at INTO stamp FROM public.user_import_recipes WHERE id='uir_refresh_transaction_test';
  result := public.refresh_verified_user_import_recipe('uir_refresh_transaction_test','other-user','ri_refresh_transaction_test',stamp,a);
  IF result THEN RAISE EXCEPTION 'Cross-user update accepted'; END IF;
  result := public.refresh_verified_user_import_recipe('uir_refresh_transaction_test','quality-test','ri_refresh_transaction_test',stamp,jsonb_set(a,'{recipe_row,source_provenance_json,quality_history,final_completeness_verified}','false'));
  IF result THEN RAISE EXCEPTION 'Unverified update accepted'; END IF;
  UPDATE public.recipe_ingestion_jobs SET dedupe_key='wrong-source' WHERE id='ri_refresh_transaction_test';
  result := public.refresh_verified_user_import_recipe('uir_refresh_transaction_test','quality-test','ri_refresh_transaction_test',stamp,a);
  IF result THEN RAISE EXCEPTION 'Wrong source accepted'; END IF;
  UPDATE public.recipe_ingestion_jobs SET dedupe_key='refresh-test-key' WHERE id='ri_refresh_transaction_test';
  BEGIN
    -- Duplicate child PK fails after deletion begins; the entire function must roll back.
    PERFORM public.refresh_verified_user_import_recipe('uir_refresh_transaction_test','quality-test','ri_refresh_transaction_test',stamp,jsonb_set(a,'{recipe_ingredients,1,id}',a#>'{recipe_ingredients,0,id}'));
    RAISE EXCEPTION 'Expected duplicate child failure';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  IF (SELECT title FROM public.user_import_recipes WHERE id='uir_refresh_transaction_test') <> 'Old partial recipe' THEN RAISE EXCEPTION 'Failed refresh changed parent'; END IF;
  result := public.refresh_verified_user_import_recipe('uir_refresh_transaction_test','quality-test','ri_refresh_transaction_test',stamp,a);
  IF NOT result THEN RAISE EXCEPTION 'Verified refresh rejected'; END IF;
  IF (SELECT count(*) FROM public.user_import_recipe_ingredients WHERE recipe_id='uir_refresh_transaction_test') <> 3 THEN RAISE EXCEPTION 'Ingredient graph mismatch'; END IF;
  IF (SELECT count(*) FROM public.user_import_recipe_steps WHERE recipe_id='uir_refresh_transaction_test') <> 2 THEN RAISE EXCEPTION 'Step graph mismatch'; END IF;
  IF (SELECT quality_flags FROM public.user_import_recipes WHERE id='uir_refresh_transaction_test') <> ARRAY[]::text[] THEN RAISE EXCEPTION 'Stale flags remain'; END IF;
  result := public.refresh_verified_user_import_recipe('uir_refresh_transaction_test','quality-test','ri_refresh_transaction_test',stamp,a);
  IF result THEN RAISE EXCEPTION 'Stale concurrent update accepted'; END IF;
  IF has_function_privilege('anon','public.refresh_verified_user_import_recipe(text,text,text,timestamp with time zone,jsonb)','EXECUTE') OR has_function_privilege('authenticated','public.refresh_verified_user_import_recipe(text,text,text,timestamp with time zone,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'Worker function exposed'; END IF;
END;
$test$;
ROLLBACK;
SELECT 'Atomic refresh, rollback, source/owner guards, stale-write rejection and privileges passed' AS result;
`;
fs.writeFileSync(process.argv[2]??'/tmp/ounje-refresh-db-test.sql',sql);
