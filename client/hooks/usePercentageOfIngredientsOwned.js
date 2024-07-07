import { useMemo } from "react";
import { useAppStore } from "../stores/app-store";

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
