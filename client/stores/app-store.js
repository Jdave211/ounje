// links: https://medium.com/@joris.l/tutorial-zustand-a-simple-and-powerful-state-management-solution-9ad4d06d5334
// - https://github.com/pmndrs/zustand

import { createStore, createPersistentStore } from "../utils/store";

const inventoryStore = (set, get) => {
  console.log({ get: get() });
  const getAllFoodItems = () => {
    const inventoryData = get().data;

    const food_items_data =
      inventoryData.items_from_images.map((item) => item.food_items) || [];

    const manually_added_items = inventoryData.manually_added_items || [];

    console.log({ food_items_data, manually_added_items });
    const food_items = [...food_items_data.flat(), ...manually_added_items];

    return food_items;
  };

  return {
    data: {
      items_from_images: [],
      manually_added_items: [],
    },
    // getFoodItemsMap: () => getAllFoodItemsMap(),
    getFoodItems: () => getAllFoodItems(),
    getImages: () => get().data.items_from_images.map((item) => item.image),
    setInventoryData: (inventory) =>
      set((state) => {
        state.data = inventory;
      }),
    addManuallyAddedItems: (items) => {
      set((state) => {
        state.data.manually_added_items.push(...items);
      });
    },
    addImagesAndItems: (images_and_their_items) => {
      set((state) => {
        state.data.items_from_images.push(...images_and_their_items);
      });
    },
    replaceImageAndItsItems: (index, image, food_items) => {
      set((state) => {
        state.data.items_from_images[index] = {
          image,
          food_items,
        };
      });
    },
  };
};

const store = (set, get) => ({
  user_id: null,
  set_user_id: (id) =>
    set((state) => {
      state.user_id = id;
    }),
  inventory: sub_store(set, get, "inventory", inventoryStore),
  clearAllAppState: () => set(() => ({})),
});

const sub_store = (set, get, name, store_fn) => {
  const sub_set = (fn) => set((state) => fn(state[name]));
  const sub_get = () => get()?.[name];
  return store_fn(sub_set, sub_get);
};

/// creates a persistent app store
export const useAppStore = createPersistentStore("ounje-app-store", store);

const generateStore = (set, get) => ({
  recipe_options: [],
  setRecipeOptions: (options) =>
    set((state) => {
      state.recipe_options = options;
    }),

  food_items: {},
  setFoodItems: (items) =>
    set((state) => {
      state.food_items = items;
    }),

  food_items_array: [],
  setFoodItemsArray: (items) =>
    set((state) => {
      state.food_items_array = items;
    }),

  detailed_food_items_map: {},
  setDetailedFoodItems: (items) =>
    set((state) => {
      state.detailed_food_items_map = items;
    }),
});

const tmpStore = (set, get) => ({
  generateStore: generateStore(set, get),
});

// creates a temporary store
export const useTmpStore = createStore(tmpStore);
