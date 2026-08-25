alter table public.first_run_guide_progress
drop constraint if exists first_run_guide_progress_phase_check;

alter table public.first_run_guide_progress
add constraint first_run_guide_progress_phase_check
check (phase in (
  'recipeSuggestion', 'planReady', 'planOpened', 'planShoppingList',
  'cartOverview', 'cartSelect', 'cartAlreadyHaveIntro', 'cartIngredient',
  'cartAlreadyHave', 'cartScope', 'cartRestoreInfo', 'cartShopNow',
  'cartChecklistOption', 'cartChecklistInfo', 'cartChecklistDone',
  'discover', 'discoverRecipe', 'recipeSave', 'recipeSavedInfo',
  'recipeCommunity', 'recipeShare', 'recipeRemix', 'recipeBack',
  'addRecipe', 'completed', 'dismissed'
));
