-- Refresh a verified same-source import without changing its recipe ID or save/plan links.
-- All content representations are replaced in one transaction. Only the worker may call it.
CREATE OR REPLACE FUNCTION public.refresh_verified_user_import_recipe(
  p_recipe_id text, p_user_id text, p_job_id text,
  p_expected_updated_at timestamptz, p_artifacts jsonb
) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE current_recipe public.user_import_recipes;
        candidate public.user_import_recipes;
        import_job public.recipe_ingestion_jobs;
BEGIN
  SELECT * INTO current_recipe FROM public.user_import_recipes
    WHERE id = p_recipe_id AND user_id = p_user_id FOR UPDATE;
  IF NOT FOUND OR current_recipe.updated_at IS DISTINCT FROM p_expected_updated_at THEN RETURN false; END IF;
  SELECT * INTO import_job FROM public.recipe_ingestion_jobs WHERE id = p_job_id AND user_id = p_user_id;
  IF NOT FOUND OR import_job.review_state <> 'approved'
    OR current_recipe.dedupe_key IS NULL
    OR import_job.dedupe_key IS DISTINCT FROM current_recipe.dedupe_key THEN RETURN false; END IF;
  -- A delayed older run must never replace a later result.
  IF EXISTS (SELECT 1 FROM public.recipe_ingestion_jobs j
      WHERE j.id = current_recipe.source_job_id AND j.created_at > import_job.created_at) THEN RETURN false; END IF;
  SELECT * INTO candidate FROM jsonb_populate_record(NULL::public.user_import_recipes,
    to_jsonb(current_recipe) || (p_artifacts->'recipe_row'));
  IF candidate.id IS DISTINCT FROM p_recipe_id OR candidate.user_id IS DISTINCT FROM p_user_id
    OR candidate.source_job_id IS DISTINCT FROM p_job_id
    OR candidate.dedupe_key IS DISTINCT FROM import_job.dedupe_key
    OR candidate.review_state <> 'approved'
    OR coalesce(candidate.confidence_score, 0) < 0.72
    OR candidate.source_provenance_json #>> '{quality_history,final_completeness_verified}' IS DISTINCT FROM 'true'
    OR candidate.quality_flags && ARRAY['partial_ingredients','partial_steps','final_validator_review_needed','final_validator_failed']
    OR jsonb_array_length(candidate.ingredients_json) < 3 OR jsonb_array_length(candidate.steps_json) < 2
  THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_artifacts->'recipe_ingredients') x WHERE x->>'recipe_id' IS DISTINCT FROM p_recipe_id)
    OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_artifacts->'recipe_steps') x WHERE x->>'recipe_id' IS DISTINCT FROM p_recipe_id)
    OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_artifacts->'recipe_step_ingredients') x
      WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_artifacts->'recipe_steps') s WHERE s->>'id' = x->>'recipe_step_id'))
    OR jsonb_array_length(p_artifacts->'recipe_ingredients') IS DISTINCT FROM jsonb_array_length(candidate.ingredients_json)
    OR jsonb_array_length(p_artifacts->'recipe_steps') IS DISTINCT FROM jsonb_array_length(candidate.steps_json)
  THEN RAISE EXCEPTION 'Invalid verified recipe graph'; END IF;
  DELETE FROM public.user_import_recipe_steps WHERE recipe_id = p_recipe_id;
  DELETE FROM public.user_import_recipe_ingredients WHERE recipe_id = p_recipe_id;
  INSERT INTO public.user_import_recipe_ingredients(id,recipe_id,ingredient_id,display_name,quantity_text,image_url,sort_order)
    SELECT id,recipe_id,ingredient_id,display_name,quantity_text,image_url,sort_order
    FROM jsonb_populate_recordset(NULL::public.user_import_recipe_ingredients,p_artifacts->'recipe_ingredients');
  INSERT INTO public.user_import_recipe_steps(id,recipe_id,step_number,instruction_text,tip_text)
    SELECT id,recipe_id,step_number,instruction_text,tip_text
    FROM jsonb_populate_recordset(NULL::public.user_import_recipe_steps,p_artifacts->'recipe_steps');
  INSERT INTO public.user_import_recipe_step_ingredients(id,recipe_step_id,ingredient_id,display_name,quantity_text,sort_order)
    SELECT id,recipe_step_id,ingredient_id,display_name,quantity_text,sort_order
    FROM jsonb_populate_recordset(NULL::public.user_import_recipe_step_ingredients,p_artifacts->'recipe_step_ingredients');
  UPDATE public.user_import_recipes SET
    title = candidate.title,
    description = candidate.description,
    author_name = candidate.author_name,
    author_handle = candidate.author_handle,
    author_url = candidate.author_url,
    source = candidate.source,
    source_platform = candidate.source_platform,
    category = candidate.category,
    subcategory = candidate.subcategory,
    recipe_type = candidate.recipe_type,
    skill_level = candidate.skill_level,
    cook_time_text = candidate.cook_time_text,
    servings_text = candidate.servings_text,
    serving_size_text = candidate.serving_size_text,
    est_calories_text = candidate.est_calories_text,
    calories_kcal = candidate.calories_kcal,
    protein_g = candidate.protein_g,
    carbs_g = candidate.carbs_g,
    fat_g = candidate.fat_g,
    prep_time_minutes = candidate.prep_time_minutes,
    cook_time_minutes = candidate.cook_time_minutes,
    hero_image_url = candidate.hero_image_url,
    discover_card_image_url = candidate.discover_card_image_url,
    recipe_url = candidate.recipe_url,
    original_recipe_url = candidate.original_recipe_url,
    attached_video_url = candidate.attached_video_url,
    detail_footnote = candidate.detail_footnote,
    image_caption = candidate.image_caption,
    source_provenance_json = candidate.source_provenance_json,
    dietary_tags = candidate.dietary_tags,
    flavor_tags = candidate.flavor_tags,
    cuisine_tags = candidate.cuisine_tags,
    occasion_tags = candidate.occasion_tags,
    main_protein = candidate.main_protein,
    cook_method = candidate.cook_method,
    ingredients_text = candidate.ingredients_text,
    instructions_text = candidate.instructions_text,
    ingredients_json = candidate.ingredients_json,
    steps_json = candidate.steps_json,
    servings_count = candidate.servings_count,
    source_job_id = candidate.source_job_id,
    dedupe_key = candidate.dedupe_key,
    review_state = candidate.review_state,
    confidence_score = candidate.confidence_score,
    quality_flags = candidate.quality_flags
  WHERE id = p_recipe_id AND user_id = p_user_id;
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.refresh_verified_user_import_recipe(text,text,text,timestamptz,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_verified_user_import_recipe(text,text,text,timestamptz,jsonb) TO service_role;
