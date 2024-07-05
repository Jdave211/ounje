import axios from "axios";
import { supabase, fetchImageSignedUrl, fetchFoodItems } from "./supabase";

export const server_link = (path) => {
  let baseUrl = "https://api.ounje.net";

  if (process.env.NODE_ENV === "development") {
    baseUrl = "http://localhost:8080";
  }
  const url = new URL(path, baseUrl);

  return url.toString();
};

export const fetchInventoryData = async (userId) => {
  const url = server_link(`/v1/inventory?user_id=${userId}`);
  const { data: inventory } = await axios.get(url);

  const images = inventory.items_from_images.map((item) => item.image);
  const signedUrls = await fetchImageSignedUrl("inventory_images", images);

  let food_ids = inventory.items_from_images
    .map((item) => item.food_items)
    .flat();

  food_ids.push(...inventory.manually_added_items);

  const foodItems = await fetchFoodItems("id", food_ids);

  const food_items_map = foodItems.reduce((acc, item) => {
    acc[item.id] = item;
    return acc;
  }, {});

  inventory.items_from_images.forEach((item, i) => {
    item.image = signedUrls[i];
    item.food_items = item.food_items.map((id) => food_items_map[id]);
  });

  inventory.manually_added_items = inventory.manually_added_items.map(
    (id) => food_items_map[id]
  );

  return inventory;
};

export const addInventoryItem = async (userId, item_ids) => {
  const url = server_link("/v1/inventory/items");
  const { data } = await axios.post(url, {
    user_id: userId,
    items: item_ids,
  });

  return data;
};

export const removeInventoryItems = async (userId, item_ids) => {
  const url = server_link("/v1/inventory/items");
  const { data } = await axios.delete(url, {
    data: {
      user_id: userId,
      items: item_ids,
    },
  });

  return data;
};
