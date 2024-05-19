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
import { customAlphabet } from "nanoid/non-secure";
import { Buffer } from "buffer";
import axios from "axios";

import { FOOD_ITEMS_PROMPT, RECIPES_PROMPT } from "../utils/prompts";
import { openai, extract_json } from "../utils/openai";
import { supabase } from "../utils/supabase";

const nanoid = customAlphabet("abcdefghijklmnopqrstuvwxyz0123456789", 10);

export default function ImageUploadForm({ onLoading }) {
  const [images, setImages] = useState([]);
  const [imageUris, setImageUris] = useState([]);

  const pickImage = async () => {
    if (images.length >= 3) {
      return;
    }

    const { status: cameraRollPerm } =
      await ImagePicker.requestMediaLibraryPermissionsAsync();

    if (cameraRollPerm !== "granted") {
      alert(
        "Sorry, we need camera roll permissions to make this work! Please go to Settings > Oúnje and enable the permission.",
      );
      Linking.openSettings();
      return;
    }

    const { status: cameraPerm } =
      await ImagePicker.requestCameraPermissionsAsync();

    if (cameraPerm !== "granted") {
      alert(
        "Sorry, we need camera permissions to make this work! Please go to Settings > Oúnje and enable the permission.",
      );
      Linking.openSettings();
      return;
    }

    ActionSheetIOS.showActionSheetWithOptions(
      {
        options: ["Cancel", "Take Photo", "Choose from Library"],
        cancelButtonIndex: 0,
      },
      async (buttonIndex) => {
        if (buttonIndex === 1) {
          let result = await ImagePicker.launchCameraAsync({
            mediaTypes: ImagePicker.MediaTypeOptions.All,
            allowsEditing: true,
            aspect: [4, 3],
            quality: 1,
          });

          if (!result.cancelled) {
            setImages([...images, result.assets[0].uri]);
          }
        } else if (buttonIndex === 2) {
          let result = await ImagePicker.launchImageLibraryAsync({
            mediaTypes: ImagePicker.MediaTypeOptions.All,
            allowsEditing: true,
            aspect: [4, 3],
            quality: 1,
          });

          if (!result.cancelled) {
            setImages([...images, result.assets[0].uri]);
          }
        }
      },
    );
  };

  const removeImage = (index) => {
    const newImages = [...images];
    newImages.splice(index, 1);
    setImages(newImages);
  };

  async function convertImageToBase64(uri) {
    try {
      const base64 = await FileSystem.readAsStringAsync(uri, {
        encoding: FileSystem.EncodingType.Base64,
      });
      return base64; // Prefix with 'data:image/jpeg;base64,' if needed
    } catch (error) {
      console.error("Error converting to base64:", error);
    }
  }

  function base64ToBinary(base64) {
    const binaryString = atob(base64.split(",")[1]);
    const len = binaryString.length;
    const bytes = new Uint8Array(len);

    for (let i = 0; i < len; i++) {
      bytes[i] = binaryString.charCodeAt(i);
    }

    return bytes.buffer;
  }

  const store_images = async (user_id, base_64_images) => {
    const inventory_image_bucket = "inventory_images";
    const inventory_image_bucket_path = user_id;

    const image_paths = [];

    for (const base64_image of base_64_images) {
      console.log("base64_image: ", base64_image.length);
      let binary_image = Buffer.from(base64_image, "base64");
      console.log("binary_image: ", binary_image?.length);
      let nano_id = nanoid();
      let image_path = inventory_image_bucket_path + `/${nano_id}.jpeg`;

      console.log({ nano_id });
      console.log({ image_path });

      let { data, error } = await supabase.storage
        .from(inventory_image_bucket)
        .upload(image_path, binary_image);

      console.log("data: ", data);
      console.log("error: ", error);

      image_paths.push(data.fullPath);
    }

    return image_paths;
  };

  const sendImages = async () => {
    onLoading(true);

    const user_id = await AsyncStorage.getItem("user_id");
    console.log("user_id: ", user_id);

    console.log("storing images");
    const base64Images = await Promise.all(images.map(convertImageToBase64));
    const image_paths = await store_images(user_id, base64Images);

    let system_prompt = { role: "system", content: FOOD_ITEMS_PROMPT };

    let user_prompt = {
      role: "user",
      content: base64Images.map((image) => ({ image })),
    };

    console.log("calling chatgpt");

    let food_items_response = await openai.chat.completions.create({
      model: "gpt-4o",
      messages: [system_prompt, user_prompt],
    });

    console.log("chatgpt response: ", food_items_response);

    const { object: food_items, text: food_items_text } =
      extract_json(food_items_response);

    console.log({ food_items });

    await AsyncStorage.setItem("food_items", JSON.stringify(food_items));

    await supabase
      .from("inventory")
      .upsert({ user_id, images: image_paths }, { onConflict: ["user_id"] })
      .throwOnError();

    let { data: runs, error: runs_error } = await supabase
      .from("runs")
      .insert([{ user_id, images: image_paths }])
      .select()
      .throwOnError();

    if (runs_error) console.log("Error:", runs_error);
    else console.log("Added User Run:", runs);

    console.log("runs: ", runs);
    current_run = runs[runs.length - 1];

    console.log("current_run: ", current_run);

    const food_item_records = [];

    var i = 0;
    for (const [inventory_name, categories] of Object.entries(food_items)) {
      for (const [category_name, items] of Object.entries(categories)) {
        for (const item of items) {
          const record = {
            run_id: current_run.id,
            inventory: inventory_name,
            category: category_name,
            name: item.name,
            quantity: item.quantity,
          };

          food_item_records.push(record);
        }
      }
      i += 1;
    }

    console.log("food_item_records: ", food_item_records);

    await supabase.from("food_items").upsert(food_item_records).throwOnError();

    console.log("starting recipes");

    let recipe_system_prompt = { role: "system", content: RECIPES_PROMPT };
    let recipe_user_prompt = { role: "user", content: food_items_text };
    let recipe_response = await openai.chat.completions.create({
      model: "gpt-4o",
      messages: [recipe_system_prompt, recipe_user_prompt],
    });

    console.log({ recipe_response });

    let { object: recipe_options } = extract_json(recipe_response);

    console.log("recipe_options: ", recipe_options);

    await AsyncStorage.setItem(
      "recipe_options",
      JSON.stringify(recipe_options),
    );

    const recipe_option_records = [];

    for (let recipe_option of recipe_options) {
      const recipe_image_form_data = {
        prompt:
          "a zoomed out image showing the full dish of " +
          recipe_option.image_prompt,
        output_format: "jpeg",
        model: "sd3",
      };

      const response = await axios.postForm(
        `https://api.stability.ai/v2beta/stable-image/generate/sd3`,
        axios.toFormData(recipe_image_form_data, new FormData()),
        {
          validateStatus: undefined,
          responseType: "arraybuffer",
          headers: {
            Authorization: `Bearer ${process.env.STABILITY_API_KEY}`,
            Accept: "image/*",
          },
        },
      );

      if (response.status !== 200) {
        throw new Error(`${response.status}: ${response.data.toString()}`);
      }

      const recipe_image = Buffer.from(response.data);

      const recipe_image_bucket = "recipe_images";
      const recipe_image_bucket_path = `${current_run.id}/${recipe_option.name}.jpeg`;

      const bucket_upload_response = await supabase.storage
        .from(recipe_image_bucket)
        .upload(recipe_image_bucket_path, recipe_image);

      console.log("bucket_upload_response: ", bucket_upload_response);

      const {
        data: { publicUrl: recipe_image_url },
      } = supabase.storage
        .from(recipe_image_bucket)
        .getPublicUrl(recipe_image_bucket_path);

      console.log("recipe_image_url: ", recipe_image_url);

      recipe_option["image_url"] = recipe_image_url;

      console.log({ recipe_option });

      delete recipe_option.image_prompt;

      recipe_option_records.push(recipe_option);
    }

    console.log("recipe_option_records: ", recipe_option_records);

    const { data: existing_items, error: fetchError } = await supabase
      .from("recipes")
      .select("unique_id")
      .in(
        "unique_id",
        recipe_option_records.map((recipe) => recipe.unique_id),
      )
      .throwOnError();

    console.log({ existing_items });

    let existing_unique_ids = new Set(
      existing_items.map((item) => item.unique_id),
    );

    console.log({ existing_unique_ids });

    const filtered_recipe_option_records = recipe_option_records.filter(
      (recipe) => !existing_unique_ids.has(recipe.unique_id),
    );

    console.log({ filtered_recipe_option_records });

    console.assert(
      filtered_recipe_option_records.length + existing_unique_ids.length ===
        recipe_option_records.length,
    );

    await supabase
      .from("recipes")
      .insert(filtered_recipe_option_records)
      .throwOnError();

    onLoading(false);
  };

  return (
    <View style={styles.container}>
      <View style={styles.imageContainer}>
        {images.map((image, index) => (
          <View key={index} style={styles.imageBox}>
            <TouchableOpacity
              style={styles.removeButton}
              onPress={() => removeImage(index)}
            >
              <Text style={styles.removeButtonText}>-</Text>
            </TouchableOpacity>
            <Image source={{ uri: image }} style={styles.image} />
          </View>
        ))}
        {images.length < 3 && (
          <TouchableOpacity style={styles.addButton} onPress={pickImage}>
            <Text style={styles.addButtonText}>+</Text>
          </TouchableOpacity>
        )}
      </View>
      <View style={styles.buttonContainer}>
        <TouchableOpacity
          style={styles.buttonContainer}
          onPress={sendImages}
          disabled={images.length === 0}
        >
          <Text style={styles.buttonText}>Generate</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 50,
  },
  imageContainer: {
    flexDirection: "row",
    flexWrap: "wrap",
    marginBottom: 20,
  },
  imageBox: {
    width: 70,
    height: 70,
    margin: 5,
    position: "relative",
  },
  image: {
    width: "100%",
    height: "100%",
  },
  addButton: {
    width: 50,
    height: 50,
    backgroundColor: "#f0f0f0",
    justifyContent: "center",
    alignItems: "center",
    margin: 5,
  },
  addButtonText: {
    fontSize: 20,
    color: "#888",
  },
  removeButton: {
    position: "absolute",
    right: 0,
    top: 0,
    backgroundColor: "red",
    width: 20,
    height: 20,
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
    zIndex: 1,
  },
  removeButtonText: {
    color: "white",
    fontSize: 15,
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
