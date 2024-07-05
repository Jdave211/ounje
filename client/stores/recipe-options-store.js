import { createStore } from "../utils/store";

const store = (set, get) => ({
  recipe_options: [],
  setRecipeOptions: (options) =>
    set((state) => {
      state.recipe_options = options;
    }),
  clearStore: () => set(() => ({})),
});

/// creates a persistent app store
export const useRecipeOptionsStore = createStore(store);
