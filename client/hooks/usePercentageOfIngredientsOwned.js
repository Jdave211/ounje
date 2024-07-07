import { useMemo } from "react";
import { useAppStore } from "@stores/app-store";

// edited by github co-pilot
export const usePercentageOfIngredientsOwned = (recipe_details) => {
  const getInventoryFoodItems = useAppStore(
    (state) => state.inventory.getFoodItems
  );
  const food_items = getInventoryFoodItems();

  const inventory_food_items_set = useMemo(() => {
    return new Set(
      food_items?.map(({ spoonacular_id }) => spoonacular_id) || []
    );
  }, [food_items]);

  const percentage = useMemo(() => {
    if (!recipe_details || inventory_food_items_set.length === 0) return 0;

    const ingredients = recipe_details.extended_ingredients;
    const owned_items = ingredients.filter((ingredient) =>
      inventory_food_items_set.has(ingredient.id)
    );

    return (owned_items.length / ingredients.length) * 100;
  }, [recipe_details, inventory_food_items_set]);

  return percentage;
};

export const useInventoryHooks = () => {
  const getInventoryFoodItems = useAppStore(
    (state) => state.inventory.getFoodItems
  );
  const food_items = getInventoryFoodItems();

  const inventory_food_items_set = useMemo(() => {
    return new Set(
      food_items?.map(({ spoonacular_id }) => spoonacular_id) || []
    );
  }, [food_items]);

  const separateIngredients = (recipe_details) => {
    if (!recipe_details || inventory_food_items_set.length === 0) return 0;

    const ingredients = recipe_details.extended_ingredients;

    const owned_items = [];
    const missing_items = [];

    ingredients.forEach((ingredient) => {
      if (inventory_food_items_set.has(ingredient.id)) {
        owned_items.push(ingredient);
      } else {
        missing_items.push(ingredient);
      }
    });

    return {
      owned_items,
      missing_items,
    };
  };

  return { separateIngredients };
};