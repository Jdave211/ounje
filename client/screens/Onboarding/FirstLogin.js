import React, { useState } from "react";
import {
  View,
  Text,
  TextInput,
  Alert,
  Image,
  StyleSheet,
  TouchableOpacity,
  ImageBackground,
  ActivityIndicator,
  ActionSheetIOS,
  ScrollView,
} from "react-native";
import * as ImagePicker from "expo-image-picker";
import { supabase } from "../../utils/supabase";
import { MaterialCommunityIcons } from "@expo/vector-icons";
import name_bg from "../../assets/name_bg.jpg";
import diet_bg from "../../assets/diet_bg.jpeg";
import fridge_bg from "../../assets/fridge_bg.jpg";
import camera_icon from "../../assets/camera_icon.png";
import { MultipleSelectList } from "../../components/MultipleSelectList";
import { FontAwesome5 } from "@expo/vector-icons";
import AsyncStorage from "@react-native-async-storage/async-storage";
import * as FileSystem from "expo-file-system";
import { customAlphabet } from "nanoid/non-secure";
import { Buffer } from "buffer";
import { openai, extract_json } from "../../utils/openai";
import { FOOD_ITEMS_PROMPT } from "../../utils/prompts";
import {
  flatten_nested_objects,
  parse_ingredients,
} from "../../utils/spoonacular";

const nanoid = customAlphabet("abcdefghijklmnopqrstuvwxyz0123456789", 10);

const FirstLogin = ({ onProfileComplete, session }) => {
  const [name, setName] = useState("");
  const [dietaryRestrictions, setDietaryRestrictions] = useState([]);
  const [fridgeImages, setFridgeImages] = useState([]);
  const [fridgeImageUris, setFridgeImageUris] = useState([]);
  const [currentQuestion, setCurrentQuestion] = useState(0);
  const [selected, setSelected] = useState([]);
  const [loading, setLoading] = useState(false);
  const images = [];

  const bg = [name_bg, diet_bg, fridge_bg];

  const dietaryRestrictionsOptions = [
    "Vegetarian",
    "Lactose Intolerant",
    "Gluten Intolerance",
    "Nut Allergy",
    "Diabetic",
  ];

  const convertImageToBase64 = async (uri) => {
    try {
      console.log("Converting image to base64:", uri);
      const base64 = await FileSystem.readAsStringAsync(uri, {
        encoding: FileSystem.EncodingType.Base64,
      });
      return base64;
    } catch (error) {
      console.error("Error converting image to base64:", error);
      throw error;
    }
  };

  const confirmSaveProfileWithoutImages = () => {
    Alert.alert(
      "No Fridge Images",
      "You have not provided any fridge images. Do you want to continue without adding fridge images?",
      [
        {
          text: "Cancel",
          style: "cancel",
        },
        {
          text: "Continue",
          onPress: () => saveProfile(true),
        },
      ],
      { cancelable: true },
    );
  };

  const pickImage = async () => {
    const { status: cameraRollPerm } =
      await ImagePicker.requestMediaLibraryPermissionsAsync();

    if (cameraRollPerm !== "granted") {
      alert("Sorry, we need camera roll permissions to make this work!");
      return;
    }

    const { status: cameraPerm } =
      await ImagePicker.requestCameraPermissionsAsync();

    if (cameraPerm !== "granted") {
      alert("Sorry, we need camera permissions to make this work!");
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

          if (!result.canceled) {
            console.log("Camera result:", result);
            const uri = result.assets[0].uri;
            setFridgeImageUris((prevUris) => [...prevUris, uri]);
            const base64Image = await convertImageToBase64(uri);
            setFridgeImages((prevImages) => [...prevImages, base64Image]);
          }
        } else if (buttonIndex === 2) {
          let result = await ImagePicker.launchImageLibraryAsync({
            mediaTypes: ImagePicker.MediaTypeOptions.All,
            allowsEditing: true,
            aspect: [4, 3],
            quality: 1,
          });

          if (!result.canceled) {
            console.log("Library result:", result);
            const uri = result.assets[0].uri;
            setFridgeImageUris((prevUris) => [...prevUris, uri]);
            const base64Image = await convertImageToBase64(uri);
            setFridgeImages((prevImages) => [...prevImages, base64Image]);
          }
        }
      },
    );
  };

  const storeImages = async (userId, base64Images) => {
    const inventoryImageBucket = "inventory_images";
    const inventoryImageBucketPath = userId;

    const uploadImage = async (base64Image) => {
      try {
        // Convert base64 to ArrayBuffer
        const byteCharacters = atob(base64Image);
        const byteNumbers = new Array(byteCharacters.length);
        for (let i = 0; i < byteCharacters.length; i++) {
          byteNumbers[i] = byteCharacters.charCodeAt(i);
        }
        const byteArray = new Uint8Array(byteNumbers);
        const arrayBuffer = byteArray.buffer;

        let nanoId = nanoid();
        let imagePath = `${inventoryImageBucketPath}/${nanoId}.jpeg`;
        images.push(imagePath);

        console.log({ nanoId });
        console.log({ imagePath });
        console.log("ArrayBuffer size: ", arrayBuffer.byteLength);

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

        console.log("Image uploaded successfully: ", data.path);

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

  const sendImages = async () => {
    setLoading(true); // Show loading indicator

    try {
      const user_id = await AsyncStorage.getItem("user_id"); // Using session user id directly
      console.log("user_id: ", user_id);

      const async_image_paths = await storeImages(user_id, fridgeImages);
      console.log("async_image_paths: ", async_image_paths);

      let system_prompt = { role: "system", content: FOOD_ITEMS_PROMPT };
      let user_prompt = {
        role: "user",
        content: fridgeImages.map((image) => ({ image })),
      };
      // console.log("Sending prompts to OpenAI:", system_prompt, user_prompt);

      let async_food_items_response = await openai.chat.completions.create({
        model: "gpt-4o",
        messages: [system_prompt, user_prompt],
      });

      console.log("OpenAI response: ", async_food_items_response);

      const [{ value: image_paths }, { value: food_items_response }] =
        await Promise.allSettled([
          async_image_paths,
          async_food_items_response,
        ]);

      console.log("image_paths: ", image_paths);
      console.log("food_items_response: ", food_items_response);

      const { object: food_items, text: food_items_text } =
        extract_json(food_items_response);
      console.log("Extracted food_items: ", food_items);

      let food_items_array = flatten_nested_objects(food_items, [
        "inventory",
        "category",
      ]);

      const parsed_ingredients = await parse_ingredients(
        food_items_array.map(({ name }) => name),
      );
      console.log("Parsed ingredients: ", parsed_ingredients);

      food_items_array = food_items_array.map((food_item, i) => {
        for (let parsed of parsed_ingredients) {
          if (parsed.original === food_item.name) {
            food_item.spoonacular_id = parsed.id;
            food_item.spoonacular_name = parsed.name;
            food_item.amount = parsed.amount;
            food_item.image = parsed.image;
            break;
          }
        }

        return food_item;
      });

      console.log("food_items_array", { food_items_array });

      await AsyncStorage.setItem("food_items", JSON.stringify(food_items));
      await AsyncStorage.setItem(
        "food_items_array",
        JSON.stringify(food_items_array),
      );

      setLoading(false);
    } catch (error) {
      console.error("Error in sendImages:", error);
    } finally {
      setLoading(false); // Hide loading indicator
    }
  };

  const saveProfile = async (continueWithoutImages = false) => {
    setLoading(true);

    try {
      console.log("Fetching user...");
      const {
        data: { user },
        error: userError,
      } = await supabase.auth.getUser();

      if (userError) {
        console.error("Error fetching user:", userError);
        throw userError;
      }

      if (fridgeImages.length === 0 && !continueWithoutImages) {
        console.log("No fridge images selected");
        setLoading(false);
        confirmSaveProfileWithoutImages();
        return;
      }

      if (fridgeImages.length > 0) {
        console.log("Uploading fridge images...");
        await storeImages(user.id, fridgeImages);
        console.log("Fridge images uploaded");

        // Call sendImages to process and store the food items
        await sendImages();
      }

      console.log("Updating profile...");
      const updates = {
        id: user.id,
        name: name,
        dietary_restriction: selected,
      };

      const { error: profileError } = await supabase
        .from("profiles")
        .upsert(updates, {
          returning: "minimal",
        });

      if (profileError) {
        console.error("Error updating profile:", profileError);
        throw profileError;
      }

      Alert.alert("Profile saved successfully");
      onProfileComplete?.();
    } catch (error) {
      console.error("Error in saveProfile:", error);
      Alert.alert("Error saving profile", error.message);
    } finally {
      setLoading(false);
    }
  };

  const questions = [
    <View style={styles.name}>
      <Text style={styles.name_text}>Hi there, what is your name?</Text>
      <TextInput
        style={{
          height: 40,
          borderColor: "gray",
          borderWidth: 2,
          color: "#f0fff0",
          fontWeight: "bold",
          marginTop: 20,
        }}
        onChangeText={(text) => setName(text)}
        value={name}
      />
    </View>,
    <View style={styles.name}>
      <Text style={styles.name_text}>
        Do you have any dietary restrictions?
      </Text>
      <MultipleSelectList
        showSelectedNumber
        setSelected={setSelected}
        selectedTextStyle={styles.selectedTextStyle}
        dropdownTextStyles={{ color: "#f0fff0" }}
        data={dietaryRestrictionsOptions}
        save="value"
        maxHeight={900}
        placeholder={"Select dietary restrictions"}
        placeholderStyles={{ color: "white" }}
        arrowicon={
          <FontAwesome5 name="chevron-down" size={12} color={"white"} />
        }
        searchicon={<FontAwesome5 name="search" size={12} color={"white"} />}
        search={false}
        boxStyles={{
          marginTop: 10,
          marginBottom: 10,
          borderColor: "white",
        }}
        badgeStyles={{ backgroundColor: "green" }}
      />
    </View>,
    <View style={styles.fridge}>
      <Text style={styles.fridge_text}>
        And finally, please click on the camera to take a picture of your fridge
      </Text>
      <View
        style={{
          justifyContent: "center",
          alignItems: "center",
          marginTop: 20,
        }}
      >
        <TouchableOpacity style={styles.camera} onPress={pickImage}>
          <Image source={camera_icon} style={{ width: 50, height: 50 }} />
        </TouchableOpacity>
        <ScrollView horizontal>
          {fridgeImageUris.map((uri, index) => (
            <Image
              key={index}
              source={{ uri }}
              style={{ width: 100, height: 100, margin: 5 }}
            />
          ))}
        </ScrollView>
      </View>
    </View>,
  ];

  return (
    <ImageBackground source={bg[currentQuestion]} style={styles.container}>
      <View style={styles.container}>
        {loading ? (
          <ActivityIndicator size="large" color="#00ff00" />
        ) : (
          questions[currentQuestion]
        )}
      </View>
      {!loading && currentQuestion < 2 && (
        <TouchableOpacity
          style={styles.next_button}
          onPress={() => {
            if (name.trim() === "" && currentQuestion === 0) {
              Alert.alert("Error", "Name is required");
            } else {
              setCurrentQuestion(currentQuestion + 1);
            }
          }}
        >
          <MaterialCommunityIcons name="page-next" size={24} color="white" />
        </TouchableOpacity>
      )}
      {!loading && currentQuestion === 2 && (
        <TouchableOpacity
          style={styles.next_button}
          onPress={() => {
            if (fridgeImages.length === 0) {
              confirmSaveProfileWithoutImages();
            } else {
              saveProfile();
            }
          }}
        >
          <MaterialCommunityIcons name="check-circle" size={24} color="white" />
        </TouchableOpacity>
      )}
    </ImageBackground>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: "center",
    padding: 20,
  },
  name_text: {
    color: "#f0fff0",
    fontWeight: "bold",
  },
  name: {
    backgroundColor: "#0f0f0f",
    padding: 20,
    borderRadius: 10,
    borderColor: "white",
    borderWidth: 1,
  },
  fridge: {
    backgroundColor: "#6D6D6D",
    padding: 20,
    borderRadius: 10,
    borderColor: "#0f0f0f",
    borderWidth: 1,
  },
  fridge_text: {
    color: "#f0fff0",
    fontWeight: "bold",
    textAlign: "center",
  },
  camera: {
    padding: 10,
    borderRadius: 10,
    alignItems: "center",
  },
  next_button: {
    position: "absolute",
    right: 20,
    bottom: 70,
    backgroundColor: "#6b9080",
    padding: 10,
    borderRadius: 10,
    borderColor: "#555b6e",
    borderWidth: 1,
    alignItems: "center",
  },
});

export default FirstLogin;
