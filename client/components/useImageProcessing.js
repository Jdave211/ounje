import { useState } from "react";
import * as FileSystem from "expo-file-system";
import { Buffer } from "buffer";
import { supabase } from "@utils/supabase";
import { openai, extract_json } from "../utils/openai";
import { FOOD_ITEMS_PROMPT } from "@utils/prompts";
import { parse_ingredients } from "../utils/spoonacular";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { customAlphabet } from "nanoid/non-secure";

const nanoid = customAlphabet("abcdefghijklmnopqrstuvwxyz0123456789", 10);

const useImageProcessing = () => {
  const [loading, setLoading] = useState(false);

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

  const storeImages = async (userId, base64Images) => {
    const inventoryImageBucket = "inventory_images";
    const inventoryImageBucketPath = userId;
    const images = [];

    const uploadImage = async (base64Image) => {
      try {
        // Convert base64 to ArrayBuffer
        const byteCharacters = Buffer.from(base64Image, "base64").toString(
          "binary",
        );
        const byteNumbers = new Array(byteCharacters.length);
        for (let i = 0; i < byteCharacters.length; i++) {
          byteNumbers[i] = byteCharacters.charCodeAt(i);
        }
        const byteArray = new Uint8Array(byteNumbers);
        const arrayBuffer = byteArray.buffer;

        let nanoId = nanoid();
        let imagePath = `${inventoryImageBucketPath}/${nanoId}.jpeg`;
        images.push(imagePath);

        let { data, error } = await supabase.storage
          .from(inventoryImageBucket)
          .upload(imagePath, arrayBuffer, {
            contentType: "image/jpeg",
            cacheControl: "3600",
            upsert: false,
          });

        if (error) {
          console.error("Error uploading image to storage:", error);
          throw error;
        }

        // Add image path to inventory_images table
        const { data: insertData, error: insertError } = await supabase
          .from("inventory")
          .upsert([{ user_id: userId, images: images }]);

        if (insertError) {
          console.error(
            "Error inserting image URL into the database:",
            insertError,
          );
          throw insertError;
        }

        return data.path;
      } catch (error) {
        console.error("Error in uploadImage function:", error);
        throw error;
      }
    };

    try {
      return await Promise.all(base64Images.map(uploadImage));
    } catch (error) {
      console.error("Error in storeImages function:", error);
      throw error;
    }
  };

  const sendImages = async (fridgeImages) => {
    setLoading(true);

    try {
      const userId = await AsyncStorage.getItem("user_id");

      await storeImages(userId, fridgeImages);

      const systemPrompt = {
        role: "system",
        content: "FOOD_ITEMS_PROMPT",
      };
      const userPrompt = {
        role: "user",
        content: fridgeImages.map((image) => ({ image })),
      };

      const asyncFoodItemsResponse = await openai.chat.completions.create({
        model: "gpt-4o",
        messages: [systemPrompt, userPrompt],
      });

      const [{ value: foodItemsResponse }] = await Promise.allSettled([
        asyncFoodItemsResponse,
      ]);

      const { object: foodItems, text: foodItemsText } =
        extract_json(foodItemsResponse);

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

      const foodItemNames = extractNames(foodItems);

      const parsedIngredients = await parse_ingredients(foodItemNames);

      const simplifiedFoodItemsArray = parsedIngredients.map((parsed) => ({
        name: parsed.original,
        spoonacular_id: parsed.id,
      }));

      const detailedFoodItemsMap = foodItems;

      await AsyncStorage.setItem(
        "food_items_array",
        JSON.stringify(simplifiedFoodItemsArray),
      );
      await AsyncStorage.setItem(
        "detailed_food_items_map",
        JSON.stringify(detailedFoodItemsMap),
      );

      setLoading(false);
    } catch (error) {
      console.error("Error in sendImages:", error);
      setLoading(false);
    }
  };

  return { loading, convertImageToBase64, sendImages };
};

export default useImageProcessing;
