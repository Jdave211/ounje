alter table public.first_run_guide_progress
drop constraint if exists first_run_guide_progress_phase_check;

alter table public.first_run_guide_progress
add constraint first_run_guide_progress_phase_check
check (phase in (
  'recipeSuggestion', 'planReady', 'planOpened', 'planShoppingList',
  'cartSelect', 'cartIngredient', 'cartAlreadyHave', 'cartScope',
  'cartShopNow', 'discover', 'discoverRecipe', 'addRecipe',
  'completed', 'dismissed'
));
