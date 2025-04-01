import { useState } from "react";
import * as FileSystem from "expo-file-system";
import { Buffer } from "buffer";
import { Alert } from "react-native";
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
    if (!userId) {
      Alert.alert("Error", "User ID is required");
      return;
    }

    setLoading(true);
    try {
      // Step 1: Upload images
      let image_paths;
      try {
        image_paths = await uploadImages(userId, fridgeImages);
        console.log("Images uploaded successfully", { image_paths });
      } catch (error) {
        console.error("Error uploading images:", error);
        throw new Error("Failed to upload images. Please try again.");
      }

      // Step 2: Extract food items from image
      let foodItemsObject;
      try {
        foodItemsObject = await extractFoodItemsFromImage(fridgeImages);
        console.log("Food items extracted successfully");
      } catch (error) {
        console.error("Error extracting food items:", error);
        throw new Error("Failed to analyze the image contents. Please try again.");
      }

      // Step 3: Process food items
      const foodItemNames = extractNames(foodItemsObject);
      if (!foodItemNames || foodItemNames.length === 0) {
        throw new Error("No food items were detected in the image. Please try again with a clearer image.");
      }
      console.log(`Found ${foodItemNames.length} food items`);

      // Step 4: Parse ingredients
      let parsed_ingredients;
      try {
        parsed_ingredients = await parse_ingredients(foodItemNames);
        console.log("Ingredients parsed successfully");
      } catch (error) {
        console.error("Error parsing ingredients:", error);
        throw new Error("Failed to process food items. Please try again.");
      }

      const parsed_food_items = parsed_ingredients.filter(
        ({ spoonacular_id }) => !!spoonacular_id
      );

      if (parsed_food_items.length === 0) {
        throw new Error("Could not recognize any valid food items. Please try again with different items.");
      }

      // Step 5: Store food items
      let stored_food_items;
      try {
        stored_food_items = await storeNewFoodItems(parsed_food_items);
        console.log("Food items stored successfully");
      } catch (error) {
        console.error("Error storing food items:", error);
        throw new Error("Failed to save food items. Please try again.");
      }

      // Create mappings
      const stored_food_items_map_by_spoonacular_id = stored_food_items.reduce(
        (acc, item) => {
          if (item?.spoonacular_id) {
            acc[item.spoonacular_id] = item;
          }
          return acc;
        },
        {}
      );

      const parsed_food_items_map_by_original = parsed_food_items.reduce(
        (acc, item) => {
          if (item.original && item?.spoonacular_id) {
            acc[item.original] = stored_food_items_map_by_spoonacular_id[item.spoonacular_id];
          }
          return acc;
        },
        {}
      );

      // Map food items to images
      const food_items_by_image = Object.entries(foodItemsObject).map(
        ([image_name, value], i) => {
          const food_item_names = extractNames(value);
          const food_item_ids = food_item_names
            .map((item) => {
              const parsed_item = parsed_food_items_map_by_original[item];
              return parsed_item?.id || null;
            })
            .filter((item) => !!item);

          return {
            name: image_name,
            image: image_paths[i],
            food_items: food_item_ids,
          };
        }
      );

      // Step 6: Update inventory
      try {
        // First delete existing images
        await axios.delete(server_link("v1/inventory/images/"), {
          data: { user_id: userId },
        });

        // Then add new images and food items
        await axios.post(server_link("v1/inventory/images/"), {
          user_id: userId,
          images_and_food_items: food_items_by_image,
        });

        console.log("Inventory updated successfully");
        const totalItems = food_items_by_image.reduce((sum, img) => sum + img.food_items.length, 0);
        const message = totalItems > 0
          ? `Successfully detected ${totalItems} items in your image!`
          : "Image uploaded but no items were detected. Try taking a clearer photo.";
        Alert.alert("Success", message);
        return true;
      } catch (error) {
        console.error("Error updating inventory:", error);
        throw new Error("Failed to update inventory. Please try again.");
      }

    } catch (error) {
      console.error("Error during image processing:", error);
      Alert.alert(
        "Error",
        error.message || "An error occurred while processing the images. Please try again."
      );
    } finally {
      setLoading(false);
    }
  };
  

  return { loading, setLoading,convertImageToBase64, sendImages, storeCaloryImages };
};

export default useImageProcessing;
