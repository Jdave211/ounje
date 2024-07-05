import { create } from "zustand";

// for reducing nested state updates
// allows you to do: `state.object.user_id = id `
// instead of `return { ...state, object: { ...state.object, user_id: id } `
import { immer } from "zustand/middleware/immer";
import { devtools, persist, createJSONStorage } from "zustand/middleware"; // persists to local storage
import AsyncStorage from "@react-native-async-storage/async-storage";
import { add, mergeDeepLeft } from "ramda";

export const createPersistentStore = (unique_store_name, store) =>
  create(
    devtools(
      persist(immer(store), {
        name: unique_store_name,
        storage: createJSONStorage(() => AsyncStorage),
        merge: (persistedState, currentState) =>
          mergeDeepLeft(persistedState, currentState),
      })
    )
  );
export const createStore = (store) => create(immer(store));
