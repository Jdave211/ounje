import "react-native-url-polyfill/auto";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { createClient } from "@supabase/supabase-js";
import { generate_image } from "./stability";

const supabaseUrl = "https://kmvqftoebsmmkhxrgdye.supabase.co";
const supabaseAnonKey =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImttdnFmdG9lYnNtbWtoeHJnZHllIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MTU3NDIxMzcsImV4cCI6MjAzMTMxODEzN30.l3Tbzuyjw7jXGfIxG6_NJc5zsUn1CHV13H3yBs0VsM0";

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    storage: AsyncStorage,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});

export const store_image = async (bucket, image_path, image) => {
  let { data: response, error } = await supabase.storage
    .from(bucket)
    .upload(image_path, image);

  if (error) throw new Error(error);

  return response;
};

export const fetchIsRecipeSavedByUser = async (user_id, id) => {
  const { data: saved_data } = await supabase
    .from("saved_recipes")
    .select()
    .eq("user_id", user_id)
    .eq("recipe_id", id)
    .throwOnError();

  return saved_data?.length > 0;
};

export const fetchSavedRecipesByUser = async (user_id) => {
  if (!user_id) throw new Error("User ID not available yet");

  const { data: recipes, error } = await supabase
    .from("saved_recipes")
    .select("recipe_id")
    .eq("user_id", user_id)
    .throwOnError();

  console.log({ saved_recipes: recipes });

  if (recipes) {
    // Use a Set to store unique recipe_ids
    const uniqueRecipeIds = Array.from(
      new Set(recipes.map(({ recipe_id }) => recipe_id))
    );

    return uniqueRecipeIds;
  }

  return [];
};

export const fetchUserProfile = async (userId) => {
  if (!userId) throw new Error("User ID not available when fetching profile");

  const { data: profileData } = await supabase
    .from("profiles")
    .select("*")
    .eq("id", userId)
    .single()
    .throwOnError();

  console.log({ profileData });

  if (profileData) return profileData;

  throw error;
};

export const fetchInventoryData = async (userId) => {
  if (!userId) throw new Error("User ID not available when fetching inventory");

  const { data: inventoryData } = await supabase
    .from("inventory")
    .select("*")
    .eq("user_id", userId)
    .single()
    .throwOnError();

  let images = inventoryData.images.map((image) =>
    image.replace("inventory_images/", "")
  );
  return { ...inventoryData, images };
};

export const fetchInventoryImages = async (userId) => {
  const inventoryData = await fetchInventoryData(userId);

  const { data: signedUrls } = await supabase.storage
    .from("inventory_images")
    .createSignedUrls(inventoryData.images, 60 * 10);

  const images = signedUrls.map(({ signedUrl }) => signedUrl);
  return images;
};

export const fetchImageSignedUrl = async (store, image_paths) => {
  const { data: signedUrls } = await supabase.storage
    .from(store)
    .createSignedUrls(image_paths, 60 * 10);

  const urls = signedUrls.map(({ signedUrl }) => signedUrl);
  return urls;
};
export const fetchRecipes = async (id_type, ids) => {
  // id_type can be "id" or "spoonacular_id"
  if (["id", "spoonacular_id"].includes(id_type) === false) {
    throw new Error("Invalid id_type");
  }

  console.log({ id_type, ids });
  const { data: recipes, error } = await supabase
    .from("recipe_ids")
    .select("*")
    .in(id_type, ids)
    .throwOnError();

  return recipes;
};

export const fetchFoodItems = async (id_type, ids) => {
  // id_type can be "id" or "spoonacular_id"
  if (
    ["id", "spoonacular_id", "original_name", "name"].includes(id_type) ===
    false
  ) {
    throw new Error("Invalid id_type");
  }
  console.log({ id_type, ids });
  const { data: foodItems, error } = await supabase
    .from("food_items")
    .select("*")
    .in(id_type, ids)
    .throwOnError();

  return foodItems;
};

export const storeNewFoodItems = async (parsed_food_items) => {
  const extract_spoonacular_ids = (list) =>
    list
      .filter((item) => !!item.spoonacular_id)
      .map((item) => item.spoonacular_id);

  const all_food_item_ids = extract_spoonacular_ids(parsed_food_items);
  const existing_food_items = await fetchFoodItems(
    "spoonacular_id",
    all_food_item_ids
  );

  const existing_food_items_set = new Set(
    extract_spoonacular_ids(existing_food_items)
  );

  const new_food_items = parsed_food_items.filter(
    (item) => !existing_food_items_set.has(item.spoonacular_id)
  );

  await supabase.from("food_items").insert(new_food_items).throwOnError();

  const new_food_item_ids = extract_spoonacular_ids(new_food_items);
  const new_food_items_with_ids = await fetchFoodItems(
    "spoonacular_id",
    new_food_item_ids
  );

  return [...existing_food_items, ...new_food_items_with_ids];
};

export const generate_and_store_image = async (
  prompt,
  image_bucket,
  image_path
) => {
  const image_bytes = await generate_image(prompt);
  return await store_image(image_bucket, image_path, image_bytes);
};