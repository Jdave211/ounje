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
import { customAlphabet } from 'nanoid/non-secure'; 
import { Buffer } from "buffer";

import openai from "../utils/openai";
import { supabase } from "../utils/supabase";

const nanoid = customAlphabet('abcdefghijklmnopqrstuvwxyz0123456789', 10); 

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
        "Sorry, we need camera roll permissions to make this work! Please go to Settings > Oúnje and enable the permission."
      );
      Linking.openSettings();
      return;
    }

    const { status: cameraPerm } =
      await ImagePicker.requestCameraPermissionsAsync();

    if (cameraPerm !== "granted") {
      alert(
        "Sorry, we need camera permissions to make this work! Please go to Settings > Oúnje and enable the permission."
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
      }
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

  const sendImages = async () => {
    onLoading(true);

    const user_id = await AsyncStorage.getItem("user_id");
    console.log("user_id: ", user_id);

    const base64Images = await Promise.all(images.map(convertImageToBase64));

    console.log("storing images");

    const inventory_image_bucket = "inventory_images";
    const inventory_image_bucket_path = user_id;

    const image_paths = [];
    
    for (const base64_image of base64Images) {
      console.log("base64_image: ", base64_image.length);
      let binary_image = Buffer.from(base64_image, 'base64');
      console.log("binary_image: ", binary_image?.length);
      let nano_id = nanoid();
      let image_path = inventory_image_bucket_path + `/${nano_id}.jpeg`;

      console.log({nano_id})
      console.log({image_path})

      let { data, error } = await supabase.storage
        .from(inventory_image_bucket)
        .upload(image_path, binary_image);

      console.log("data: ", data);
      console.log("error: ", error);

      image_paths.push(image_path);
    }

    let system_prompt = {
      role: "system",
      content: `List all the food items in each of these food inventories in an array. 
    Within each inventory, break the food items in similar food categories that describe the food items (e.g. fruits, condiments, drinks, meats, etc.).
    Be as specific as possible for each individual item even if they are in a category and include the quantity of each item such that we have enough 
    information to create a recipe for a meal. 
    The quantity should only be a number indicating the amount of the named item in the inventory.
    Categorize them into this format:
    { "inventory_name": { "category_name": {name: text, quantity: number} }}.
    Follow the types in the format strictly. numbers should only be numbers and text should only be text.
    The image name should represent the environment where the food items are found.`,
    };

    let user_prompt = {
      role: "user",
      content: base64Images.map((image) => ({ image })),
    };

    const extract_json = (data) => {
      console.log("messages: ", data.choices.length);

      const content = data.choices
        .map((choice) => choice.message.content)
        .join("");
      const regex = /^```json([\s\S]*?)^```/gm;
      const matches = regex.exec(content);

      let json_text = matches?.[0].replace(/^```json\n|\n```$/g, "") || content; // Remove the code block markers
      console.log({ json_text });
      let object = JSON.parse(json_text);

      return {
        object,
        text: json_text,
      };
    };

    console.log("calling chatgpt");

    let food_items_response = await openai.chat.completions.create({
      model: "gpt-4o",
      messages: [system_prompt, user_prompt],
    });

    console.log("chatgpt response: ", food_items_response);

    const { object: food_items } = extract_json(food_items_response);

    console.log("food_items: ", food_items);

    await supabase.from("inventory")
      .upsert({ user_id, images: image_paths },  { onConflict: ['user_id'] })
      .throwOnError();

    let { data: runs, error: runs_error } = await supabase.from("runs")
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

    await supabase.from("food_items")
      .upsert(food_item_records)
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
