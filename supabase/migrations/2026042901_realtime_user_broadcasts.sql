CREATE SCHEMA IF NOT EXISTS private;

CREATE OR REPLACE FUNCTION private.ounje_emit_user_broadcast()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  next_row jsonb;
  prev_row jsonb;
  row_data jsonb;
  effective_user_id text;
  effective_record_id text;
  event_name text;
  payload jsonb;
BEGIN
  next_row := CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END;
  prev_row := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END;
  row_data := COALESCE(next_row, prev_row);

  effective_user_id := NULLIF(
    COALESCE(
      row_data ->> 'user_id',
      row_data ->> 'id'
    ),
    ''
  );
  event_name := NULLIF(COALESCE(TG_ARGV[0], ''), '');

  IF effective_user_id IS NULL OR event_name IS NULL THEN
    RETURN NULL;
  END IF;

  effective_record_id := NULLIF(
    COALESCE(
      row_data ->> 'id',
      row_data ->> 'recipe_id',
      row_data ->> 'run_id'
    ),
    ''
  );

  payload := jsonb_build_object(
    'user_id', effective_user_id,
    'table', TG_TABLE_NAME,
    'operation', TG_OP,
    'emitted_at', now()
  );

  IF effective_record_id IS NOT NULL THEN
    payload := payload || jsonb_build_object('record_id', effective_record_id);
  END IF;

  PERFORM realtime.send(
    payload,
    event_name,
    'ounje:user:' || effective_user_id,
    false
  );

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_entitlements_realtime_broadcast ON public.app_user_entitlements;
CREATE TRIGGER trg_entitlements_realtime_broadcast
  AFTER INSERT OR UPDATE OR DELETE ON public.app_user_entitlements
  FOR EACH ROW
  EXECUTE FUNCTION private.ounje_emit_user_broadcast('entitlement.updated');

DROP TRIGGER IF EXISTS trg_meal_prep_cycles_realtime_broadcast ON public.meal_prep_cycles;
CREATE TRIGGER trg_meal_prep_cycles_realtime_broadcast
  AFTER INSERT OR UPDATE OR DELETE ON public.meal_prep_cycles
  FOR EACH ROW
  EXECUTE FUNCTION private.ounje_emit_user_broadcast('meal_prep_cycle.updated');

DROP TRIGGER IF EXISTS trg_meal_prep_cycle_completions_realtime_broadcast ON public.meal_prep_cycle_completions;
CREATE TRIGGER trg_meal_prep_cycle_completions_realtime_broadcast
  AFTER INSERT OR UPDATE OR DELETE ON public.meal_prep_cycle_completions
  FOR EACH ROW
  EXECUTE FUNCTION private.ounje_emit_user_broadcast('prep.updated');

DROP TRIGGER IF EXISTS trg_prep_recipe_overrides_realtime_broadcast ON public.prep_recipe_overrides;
CREATE TRIGGER trg_prep_recipe_overrides_realtime_broadcast
  AFTER INSERT OR UPDATE OR DELETE ON public.prep_recipe_overrides
  FOR EACH ROW
  EXECUTE FUNCTION private.ounje_emit_user_broadcast('prep.updated');

DROP TRIGGER IF EXISTS trg_prep_recurring_recipes_realtime_broadcast ON public.prep_recurring_recipes;
CREATE TRIGGER trg_prep_recurring_recipes_realtime_broadcast
  AFTER INSERT OR UPDATE OR DELETE ON public.prep_recurring_recipes
  FOR EACH ROW
  EXECUTE FUNCTION private.ounje_emit_user_broadcast('prep.updated');

DROP TRIGGER IF EXISTS trg_meal_prep_automation_state_realtime_broadcast ON public.meal_prep_automation_state;
CREATE TRIGGER trg_meal_prep_automation_state_realtime_broadcast
  AFTER INSERT OR UPDATE OR DELETE ON public.meal_prep_automation_state
  FOR EACH ROW
  EXECUTE FUNCTION private.ounje_emit_user_broadcast('prep.updated');
