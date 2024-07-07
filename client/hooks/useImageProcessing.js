import { useState } from "react";
import * as FileSystem from "expo-file-system";
import { Buffer } from "buffer";
import { fetchFoodItems, supabase } from "../utils/supabase";
import { openai, extract_json } from "../utils/openai";
import { FOOD_ITEMS_PROMPT } from "../utils/prompts";
import { parse_ingredients } from "../utils/spoonacular";
import { customAlphabet } from "nanoid/non-secure";
import { useAppStore } from "../stores/app-store";
import { zip } from "itertools";
import { fetchInventoryData, storeNewFoodItems } from "../utils/supabase";
import axios from "axios";
import { server_link } from "../utils/server-api";
import { decode } from "base64-arraybuffer";

const nanoid = customAlphabet("abcdefghijklmnopqrstuvwxyz0123456789", 10);

const useImageProcessing = () => {
  const [loading, setLoading] = useState(false);
  const userId = useAppStore((state) => state.user_id);

  const convertImageToBase64 = async (uri) => {
    try {
      const base64 = await FileSystem.readAsStringAsync(uri, {
        encoding: FileSystem.EncodingType.Base64,
      });
      return base64;
    } catch (error) {
      console.error("Error converting image to base64:", error);
      throw error;
    }
  };

  const uploadImage = async (bucket_name, bucket_path, base64Image) => {
    // Convert base64 to ArrayBuffer
    let nanoId = nanoid();
    let imagePath = `${bucket_path}/${nanoId}.jpeg`;
    console.log("base64Image: ", base64Image.length);
    let { data, error } = await supabase.storage
      .from(bucket_name)
      .upload(imagePath, decode(base64Image), {
        contentType: "image/jpeg",
        cacheControl: "3600",
        upsert: false,
      });

    if (error) {
      console.error("Error uploading image to storage:", error);
      throw error;
    }

    return data.path;
  };

  const storeCaloryImages = async (userId, base64Images) => {
    try {
      const images = await uploadImages(userId, base64Images);

      // Add image path to inventory_images table
      const { data: insertData, error: insertError } = await supabase
        .from("calorie_imagedata")
        .upsert([{ user_id: userId, images }]);

      if (insertError) {
        console.error(
          "Error inserting image URL into the database:",
          insertError
        );
        throw insertError;
      }
    } catch (error) {
      console.error("Error in storeCalorieImages function:", error);
      throw error;
    }
  };

  const uploadImages = async (userId, base64Images) => {
    const image_paths = await Promise.all(
      base64Images.map(
        async (base64Image) =>
          await uploadImage("inventory_images", userId, base64Image)
      )
    );
    return image_paths;
  };

  const extractFoodItemsFromImage = async (base64Images) => {
    const systemPrompt = {
      role: "system",
      content: FOOD_ITEMS_PROMPT,
    };
    const userPrompt = {
      role: "user",
      content: base64Images.map((image) => ({ image })),
    };

    const res = await openai.chat.completions.create({
      model: "gpt-4o",
      messages: [systemPrompt, userPrompt],
      response_format: { type: "json_object" },
    });

    const json = JSON.parse(res.choices[0].message.content);
    return json;
  };

  const extractNames = (obj) => {
    const result = [];
    for (const key in obj) {
      if (Array.isArray(obj[key])) {
        obj[key].forEach((item) => {
          if (item.name) {
            result.push(item.name);
          }
        });
      } else if (typeof obj[key] === "object") {
        result.push(...extractNames(obj[key]));
      }
    }
    return result;
  };

  const sendImages = async (fridgeImages) => {
    setLoading(true);

    const image_paths = await uploadImages(userId, fridgeImages);

    console.log("stored images", { image_paths });
    const foodItemsObject = await extractFoodItemsFromImage(fridgeImages);

    console.log("extracted food items");

    const foodItemNames = extractNames(foodItemsObject);

    console.log("extracted food item names");
    const parsed_ingredients = await parse_ingredients(foodItemNames);

    const parsed_food_items = parsed_ingredients.filter(
      ({ spoonacular_id }) => !!spoonacular_id
    );

    console.log({
      foodItemNames: foodItemNames.length,
      parsed_food_items: parsed_food_items.length,
    });

    console.log("retrieved parsed_food_items");

    const stored_food_items = await storeNewFoodItems(parsed_food_items);

    const stored_food_items_map_by_spoonacular_id = stored_food_items.reduce(
      (acc, item) => {
        acc[item.spoonacular_id] = item;
        return acc;
      },
      {}
    );

    console.log({ stored_food_items_map_by_spoonacular_id });

    const parsed_food_items_map_by_original = parsed_food_items.reduce(
      (acc, item) => {
        acc[item.original] =
          stored_food_items_map_by_spoonacular_id[item.spoonacular_id];
        return acc;
      },
      {}
    );

    console.log({ parsed_food_items_map_by_original });

    const food_items_by_image = Object.entries(foodItemsObject).map(
      ([image_name, value], i) => {
        const food_item_names = extractNames(value);

        const food_item_ids = food_item_names
          .map((item) => {
            const parsed_item = parsed_food_items_map_by_original[item];

            return parsed_item?.id || null;
          })
          .filter((item) => !!item);

        console.log({
          food_item_names,
          food_item_ids,
        });

        return {
          name: image_name,
          image: image_paths[i],
          food_items: food_item_ids,
        };
      }
    );

    console.log({ food_items_by_image });

    await axios.delete(server_link("v1/inventory/images/"), {
      data: {
        user_id: userId,
      },
    });

    await axios.post(server_link("v1/inventory/images/"), {
      user_id: userId,
      images_and_food_items: food_items_by_image,
    });

    setLoading(false);
  };

  return { loading, convertImageToBase64, sendImages, storeCaloryImages };
};

export default useImageProcessing;
