import { createStore } from "../utils/store";

const store = (set, get) => ({
  dish_types: [],
  recipe_options: [],
  addDishType: (dish_type) =>
    set((state) => {
      if (state.dish_types.includes(dish_type)) return;
      state.dish_types.push(dish_type);
    }),
  setDishTypes: (dish_types) =>
    set((state) => {
      state.dish_types = dish_types;
    }),
  setRecipeOptions: (options) =>
    set((state) => {
      state.recipe_options = options;
    }),
  clearStore: () => set(() => ({})),
});

/// creates a persistent app store
export const useRecipeOptionsStore = createStore(store);
