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
  Platform,
} from "react-native";
import * as ImagePicker from "expo-image-picker";
import { fetchInventoryData, supabase } from "../../utils/supabase";
import { MaterialCommunityIcons } from "@expo/vector-icons";
import name_bg from "../../assets/name_bg.jpg";
import diet_bg from "../../assets/diet_bg.jpeg";
import fridge_bg from "../../assets/fridge_bg.jpg";
import camera_icon from "../../assets/camera_icon.png";
import { MultipleSelectList } from "../../components/MultipleSelectList";
import { FontAwesome5 } from "@expo/vector-icons";
import * as FileSystem from "expo-file-system";
import { customAlphabet } from "nanoid/non-secure";
import { Buffer } from "buffer";
import { openai, extract_json } from "../../utils/openai";
import { FOOD_ITEMS_PROMPT } from "../../utils/prompts";
import Loading from "../../components/Loading";
import {
  flatten_nested_objects,
  parse_ingredients,
} from "../../utils/spoonacular";
import useImageProcessing from "../../hooks/useImageProcessing"; // Import the custom hook
import AddItems from "./AddItems";
import { useAppStore } from "../../stores/app-store";

const nanoid = customAlphabet("abcdefghijklmnopqrstuvwxyz0123456789", 10);

const FirstLogin = ({ onProfileComplete, session }) => {
  const [name, setName] = useState("");
  const [dietaryRestrictions, setDietaryRestrictions] = useState([]);
  const [selected, setSelected] = useState([]);
  const [fridgeImages, setFridgeImages] = useState([]);
  const [fridgeImageUris, setFridgeImageUris] = useState([]);
  const [currentQuestion, setCurrentQuestion] = useState(0);

  const { loading, convertImageToBase64, sendImages } = useImageProcessing();

  const setInventoryData = useAppStore(
    (state) => state.inventory.setInventoryData
  );

  const bg = [name_bg, diet_bg, fridge_bg];

  const dietaryRestrictionsOptions = [
    "Vegetarian",
    "Lactose Intolerant",
    "Gluten Intolerance",
    "Nut Allergy",
    "Diabetic",
  ];

 
  // chnge the code for android start the camera now...
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

    if (Platform.OS === 'ios') {
      // iOS-specific ActionSheet
      ActionSheetIOS.showActionSheetWithOptions(
        {
          options: ["Cancel", "Take Photo", "Choose from Library"],
          cancelButtonIndex: 0,
        },
        async (buttonIndex) => {
          handleActionSheetSelection(buttonIndex);
        }
      );
    } else {
      // Android alternative
      Alert.alert(
        'Select Option',
        'Choose to take a photo or pick from the library',
        [
          { text: 'Cancel', style: 'cancel' },
          { text: 'Take Photo', onPress: () => handleActionSheetSelection(1) },
          { text: 'Choose from Library', onPress: () => handleActionSheetSelection(2) },
        ]
      );
    }
  };

  const handleActionSheetSelection = async (buttonIndex) => {
    if (buttonIndex === 1) {
      // Launch camera
      let result = await ImagePicker.launchCameraAsync({
        mediaTypes: ImagePicker.MediaTypeOptions.All,
        allowsEditing: true,
        aspect: [4, 3],
        quality: 1,
      });

      if (!result.canceled) {
        const uri = result.assets[0].uri;
        setFridgeImageUris((prevUris) => [...prevUris, uri]);
        const base64Image = await convertImageToBase64(uri);
        setFridgeImages((prevImages) => [...prevImages, base64Image]);
      }
    } else if (buttonIndex === 2) {
      // Pick from library
      let result = await ImagePicker.launchImageLibraryAsync({
        mediaTypes: ImagePicker.MediaTypeOptions.All,
        allowsEditing: true,
        aspect: [4, 3],
        quality: 1,
      });

      if (!result.canceled) {
        const uri = result.assets[0].uri;
        setFridgeImageUris((prevUris) => [...prevUris, uri]);
        const base64Image = await convertImageToBase64(uri);
        setFridgeImages((prevImages) => [...prevImages, base64Image]);
      }
    }
  };
  const confirmSaveProfileWithoutImages = () => {
    Alert.alert(
      "No Fridge Images",
      "You have not provided any fridge images. Do you want to continue without adding these images?",
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
      { cancelable: true }
    );
  };

  const saveProfile = async (continueWithoutImages = false) => {
    try {
      const {
        data: { user },
        error: userError,
      } = await supabase.auth.getUser();

      if (userError) {
        console.error("Error fetching user:", userError);
        throw userError;
      }

      if (fridgeImages.length === 0 && !continueWithoutImages) {
        setLoading(false);
        confirmSaveProfileWithoutImages();
        return;
      }

      if (fridgeImages.length > 0) {
        await sendImages(fridgeImages);
        const inventoryData = await fetchInventoryData(user.id);
        setInventoryData(inventoryData);
      }

      const updates = {
        id: user.id,
        name: name,
        dietary_restriction: dietaryRestrictions,
      };

      const { error: profileError } = await supabase
        .from("profiles")
        .upsert(updates, {
          returning: "representation",
          
        });
        console.log("========================================= updates: ", updates);

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
        setSelected={setDietaryRestrictions}
        selectedTextStyle={styles.selectedTextStyle}
        dropdownTextStyles={{ color: "#f0fff0" }}
        data={dietaryRestrictionsOptions.map((option) => ({
          key: option,
          value: option,
        }))}
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
          {fridgeImageUris.map(
            (uri, index) => (
              console.log(
                "===================================== fridgeImageUris",
                uri
              ),
              (
                <Image
                  key={index}
                  source={{ uri }}
                  style={{ width: 100, height: 100, margin: 5 }}
                />
              )
            )
          )}
        </ScrollView>
      </View>
    </View>,
    <View style={styles.addItemsContainer}>
      <Text style={styles.name_text}>Select items for your inventory</Text>
      <AddItems />
    </View>,
  ];

  return (
    <ImageBackground source={bg[currentQuestion]} style={styles.container}>
      <View style={styles.container}>
        {loading ? <Loading /> : questions[currentQuestion]}
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
            saveProfile();
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






















// const pickImage = async () => {
  //   const { status: cameraRollPerm } =
  //     await ImagePicker.requestMediaLibraryPermissionsAsync();

  //   if (cameraRollPerm !== "granted") {
  //     alert("Sorry, we need camera roll permissions to make this work!");
  //     return;
  //   }

  //   const { status: cameraPerm } =
  //     await ImagePicker.requestCameraPermissionsAsync();

  //   if (cameraPerm !== "granted") {
  //     alert("Sorry, we need camera permissions to make this work!");
  //     return;
  //   }

  //   ActionSheetIOS.showActionSheetWithOptions(
  //     {
  //       options: ["Cancel", "Take Photo", "Choose from Library"],
  //       cancelButtonIndex: 0,
  //     },
  //     async (buttonIndex) => {
  //       if (buttonIndex === 1) {
  //         let result = await ImagePicker.launchCameraAsync({
  //           mediaTypes: ImagePicker.MediaTypeOptions.All,
  //           allowsEditing: true,
  //           aspect: [4, 3],
  //           quality: 1,
  //         });

  //         if (!result.canceled) {
  //           const uri = result.assets[0].uri;
  //           setFridgeImageUris((prevUris) => [...prevUris, uri]);
  //           const base64Image = await convertImageToBase64(uri);
  //           setFridgeImages((prevImages) => [...prevImages, base64Image]);
  //         }
  //       } else if (buttonIndex === 2) {
  //         let result = await ImagePicker.launchImageLibraryAsync({
  //           mediaTypes: ImagePicker.MediaTypeOptions.All,
  //           allowsEditing: true,
  //           aspect: [4, 3],
  //           quality: 1,
  //         });

  //         if (!result.canceled) {
  //           const uri = result.assets[0].uri;
  //           setFridgeImageUris((prevUris) => [...prevUris, uri]);
  //           const base64Image = await convertImageToBase64(uri);
  //           setFridgeImages((prevImages) => [...prevImages, base64Image]);
  //         }
  //       }
  //     }
  //   );
  // };
