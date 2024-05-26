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
import { useNavigation } from "@react-navigation/native";
import { flatten_nested_objects } from "../../utils/openai";

const nanoid = customAlphabet("abcdefghijklmnopqrstuvwxyz0123456789", 10);

const FirstLogin = ({ onProfileComplete, session }) => {
  const navigation = useNavigation();
  const [name, setName] = useState("");
  const [dietaryRestrictions, setDietaryRestrictions] = useState([]);
  const [fridgeImage, setFridgeImage] = useState(null);
  const [fridgeImageUri, setFridgeImageUri] = useState(null);
  const [currentQuestion, setCurrentQuestion] = useState(0);
  const [selected, setSelected] = useState([]);
  const [loading, setLoading] = useState(false);

  const bg = [name_bg, diet_bg, fridge_bg];

  const dietaryRestrictionsOptions = [
    "Vegetarian",
    "Lactose Intolerant",
    "Nut Free",
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

  const pickImage = async () => {
    if (fridgeImage) {
      return;
    }

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
            setFridgeImageUri(result.assets[0].uri);
            const base64Image = await convertImageToBase64(
              result.assets[0].uri
            );
            setFridgeImage(base64Image);
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
            setFridgeImageUri(result.assets[0].uri);
            const base64Image = await convertImageToBase64(
              result.assets[0].uri
            );
            setFridgeImage(base64Image);
          }
        }
      }
    );
  };

  const storeImages = async (userId, base64Images) => {
    const inventoryImageBucket = "inventory_images";
    const inventoryImageBucketPath = userId;

    const uploadImage = async (base64Image) => {
      console.log("base64_image length: ", base64Image.length);
      let binaryImage = Buffer.from(base64Image, "base64");
      console.log("binary_image length: ", binaryImage?.length);
      let nanoId = nanoid();
      let imagePath = `${inventoryImageBucketPath}/${nanoId}.jpeg`;

      console.log({ nanoId });
      console.log({ imagePath });

      let { data, error } = await supabase.storage
        .from(inventoryImageBucket)
        .upload(imagePath, binaryImage);

      if (error) {
        console.error("Error uploading image to storage:", error);
        throw error;
      }

      return data.path;
    };

    return await Promise.all(base64Images.map(uploadImage));
  };

  const sendImages = async () => {
    setLoading(true); // Show loading indicator

    try {
      const user_id = await AsyncStorage.getItem("user_id"); // Using session user id directly
      console.log("user_id: ", user_id);

      const base64Images = [fridgeImage];
      console.log("base64Images: ", base64Images);

      const async_image_paths = await storeImages(user_id, base64Images);
      console.log("async_image_paths: ", async_image_paths);

      let system_prompt = { role: "system", content: FOOD_ITEMS_PROMPT };
      let user_prompt = {
        role: "user",
        content: base64Images.map((image) => ({ image })),
      };
      console.log("Sending prompts to OpenAI:", system_prompt, user_prompt);

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

      // const foodItemNames = extractFoodItemNames(food_items);
      // console.log("Extracted food item names: ", foodItemNames);

      const food_items_array = flatten_nested_objects(food_items, [
        "inventory",
        "category",
      ]);

      await AsyncStorage.setItem("food_items", JSON.stringify(food_items));
      await AsyncStorage.setItem(
        "food_items_array",
        JSON.stringify(food_items_array)
      );

      // const { error } = await supabase
      //   .from("inventory")
      //   .upsert(
      //     { user_id, images: image_paths, food_items: foodItemNames },
      //     { onConflict: ["user_id"] }
      //   );

      // if (error) {
      //   throw error;
      // }

      // console.log("Food items stored in the database");

      // await AsyncStorage.setItem(
      //   "food_items_array",
      //   JSON.stringify(foodItemNames)
      // );

      setLoading(false);
      navigation.navigate("CheckIngredients");
    } catch (error) {
      console.error("Error in sendImages:", error);
    } finally {
      setLoading(false); // Hide loading indicator
    }
  };

  // Helper function to extract food item names
  const extractFoodItemNames = (foodItems) => {
    const foodItemNames = [];

    const firstNestedObject = Object.values(foodItems)[0]; // Get the first nested object
    console.log("First nested object:", firstNestedObject);

    const extractNames = (items) => {
      if (Array.isArray(items)) {
        items.forEach((item) => {
          if (item && item.name) {
            foodItemNames.push(item.name);
          }
        });
      }
    };

    if (firstNestedObject) {
      // Iterate through the sections in the first nested object
      for (const section in firstNestedObject) {
        extractNames(firstNestedObject[section]);
      }
    } else {
      console.error("First nested object is undefined or null.");
    }

    return foodItemNames;
  };

  const saveProfile = async () => {
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

      let fridgeImagePath = null;
      if (fridgeImage) {
        console.log("Uploading fridge image...");
        const imagePaths = await storeImages(user.id, [fridgeImage]);
        fridgeImagePath = imagePaths[0];
        console.log("Fridge image uploaded:", fridgeImagePath);

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
          color: "white",
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
        setSelected={setSelected}
        selectedTextStyle={styles.selectedTextStyle}
        dropdownTextStyles={{ color: "white" }}
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
        And finally, please click here to take a picture of your fridge
      </Text>
      <View
        style={{
          justifyContent: "center",
          alignItems: "center",
          marginTop: 20,
        }}
      >
        {fridgeImageUri ? (
          <Image
            source={{ uri: fridgeImageUri }}
            style={{ width: 100, height: 100 }}
          />
        ) : (
          <TouchableOpacity style={styles.camera} onPress={pickImage}>
            <Image source={camera_icon} style={{ width: 50, height: 50 }} />
          </TouchableOpacity>
        )}
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
        <TouchableOpacity style={styles.next_button} onPress={saveProfile}>
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
    color: "gray",
    fontWeight: "bold",
  },
  name: {
    backgroundColor: "black",
    padding: 20,
    borderRadius: 10,
    borderColor: "white",
    borderWidth: 1,
  },
  fridge: {
    backgroundColor: "gray",
    padding: 20,
    borderRadius: 10,
    borderColor: "black",
    borderWidth: 1,
  },
  fridge_text: {
    color: "black",
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
    backgroundColor: "black",
    padding: 10,
    borderRadius: 10,
    alignItems: "center",
  },
});

export default FirstLogin;
