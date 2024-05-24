import React, { useState } from "react";
import {
  Button,
  Image,
  View,
  StyleSheet,
  TouchableOpacity,
  Text,
} from "react-native";
import * as ImagePicker from "expo-image-picker";
import * as FileSystem from "expo-file-system";
import Constants from "expo-constants";
import { ActionSheetIOS } from "react-native";
import { Linking } from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { FOOD_ITEMS } from "../utils/constants";
import { RECIPES_PROMPT } from "@utils/prompts";
import { customAlphabet } from "nanoid/non-secure";
import { Buffer } from "buffer";
import axios from "axios";

import { FOOD_ITEMS_PROMPT } from "../utils/prompts";
import { openai, extract_json, flatten_nested_objects } from "../utils/openai";
import { supabase, store_image } from "../utils/supabase";
import { generate_image } from "../utils/stability";
const nanoid = customAlphabet("abcdefghijklmnopqrstuvwxyz0123456789", 10);

export default function GenerateRecipes({ onLoading }) {
  const [images, setImages] = useState([]);
  const [imageUris, setImageUris] = useState([]);


  const sendImages = async () => {
    onLoading(true);

    const user_id = await AsyncStorage.getItem("user_id");
    console.log("user_id: ", user_id);

    const base64Images = await Promise.all(images.map(convertImageToBase64));
    const async_image_paths = store_images(user_id, base64Images);

    let system_prompt = { role: "system", content: FOOD_ITEMS_PROMPT };
    let user_prompt = {
      role: "user",
      content: base64Images.map((image) => ({ image })),
    };
    let async_food_items_response = openai.chat.completions.create({
      model: "gpt-4o",
      messages: [system_prompt, user_prompt],
    });

    console.log("calling chatgpt and storing inventory images");
    const [{ value: image_paths }, { value: food_items_response }] =
      await Promise.allSettled([async_image_paths, async_food_items_response]);

    console.log("chatgpt response: ", food_items_response);

    const { object: food_items, text: food_items_text } =
      extract_json(food_items_response);

    console.log({ food_items });

    await AsyncStorage.setItem("food_items", JSON.stringify(food_items));

    await supabase
      .from("inventory")
      .upsert({ user_id, images: image_paths }, { onConflict: ["user_id"] })
      .throwOnError();

    const food_items_array = flatten_nested_objects(food_items, [
      "inventory",
      "category",
    ]);

    await AsyncStorage.setItem(
      "food_items_array",
      JSON.stringify(food_items_array),
    );

    onLoading(false);
  };

  return (
    <View style={styles.container}>
      <View style={styles.buttonContainer}>
        <TouchableOpacity
          style={styles.buttonContainer}
          onPress={sendImages}
        >
          <Text style={styles.buttonText}>Generate</Text>
        </TouchableOpacity>
      </View>
      </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: "center",
    justifyContent: "center",
    marginTop: 20,
  },
  buttonContainer: {
    width: 200,
    height: 50,
    backgroundColor: "green",
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
  },
  buttonText: {
    color: "#fff",
    fontWeight: "bold",
  },
});
