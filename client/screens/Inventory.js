import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  Image,
  TouchableOpacity,
  Modal,
  Alert,
  TextInput,
  ActionSheetIOS,
  ActivityIndicator,
} from "react-native";
import { FontAwesome5, AntDesign } from "@expo/vector-icons";
import { MultipleSelectList } from "../components/MultipleSelectList";
import { supabase } from "../utils/supabase";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { useNavigation, useFocusEffect } from "@react-navigation/native";
import Toast from "react-native-toast-message";
import * as ImagePicker from "expo-image-picker";
import camera from "@assets/camera_icon.png";
import { parse_ingredients } from "@utils/spoonacular";
import useImageProcessing from "../components/useImageProcessing";
import { ADD_FOOD_PROMPT } from "../utils/prompts";
import { openai } from "../utils/openai";
import Loading from "../components/Loading";

const Inventory = () => {
  const navigation = useNavigation();
  const [selected, setSelected] = useState([]);
  const [modalVisible, setModalVisible] = useState(false);
  const [selectedImage, setSelectedImage] = useState(null);
  const [foodItems, setFoodItems] = useState([]);
  const [newlyAddedItems, setNewlyAddedItems] = useState([]);
  const [inventoryImages, setInventoryImages] = useState([]);
  const [userId, setUserId] = useState(null);
  const [newItem, setNewItem] = useState("");
  const [isLoading, setIsLoading] = useState(false);

  const { loading, convertImageToBase64, sendImages } = useImageProcessing();

  useEffect(() => {
    const fetchInitialData = async () => {
      const retrievedUserId = await AsyncStorage.getItem("user_id");
      setUserId(retrievedUserId);

      const retrievedArrayText = await AsyncStorage.getItem("food_items_array");
      const retrievedFoodItemsArray = JSON.parse(retrievedArrayText || "[]");
      setFoodItems(retrievedFoodItemsArray);

      if (retrievedUserId) {
        const { data: inventory } = await supabase
          .from("inventory")
          .select("images")
          .eq("user_id", retrievedUserId)
          .single();

        if (inventory) {
          const imagePaths = inventory.images.map((image) =>
            image.replace("inventory_images/", ""),
          );

          const { data: urlResponses } = await supabase.storage
            .from("inventory_images")
            .createSignedUrls(imagePaths, 60 * 10);

          const imageUrls = urlResponses.map((response) => response.signedUrl);
          setInventoryImages(imageUrls);
        }
      }
    };

    fetchInitialData();
  }, []);

  useFocusEffect(
    React.useCallback(() => {
      const fetchInitialData = async () => {
        const retrievedUserId = await AsyncStorage.getItem("user_id");
        setUserId(retrievedUserId);

        const retrievedArrayText =
          await AsyncStorage.getItem("food_items_array");
        const retrievedFoodItemsArray = JSON.parse(retrievedArrayText || "[]");
        setFoodItems(retrievedFoodItemsArray);

        if (retrievedUserId) {
          const { data: inventory } = await supabase
            .from("inventory")
            .select("images")
            .eq("user_id", retrievedUserId)
            .single();

          if (inventory) {
            const imagePaths = inventory.images.map((image) =>
              image.replace("inventory_images/", ""),
            );

            const { data: urlResponses } = await supabase.storage
              .from("inventory_images")
              .createSignedUrls(imagePaths, 60 * 10);

            const imageUrls = urlResponses.map(
              (response) => response.signedUrl,
            );
            setInventoryImages(imageUrls);
          }
        }
      };

      fetchInitialData();
    }, []),
  );

  const addNewItem = async () => {
    if (newItem.trim() === "") {
      Alert.alert("Error", "Please enter a valid item name.");
      return;
    }

    const updatedNewlyAddedItems = [...newlyAddedItems, newItem];
    setNewlyAddedItems(updatedNewlyAddedItems);
    Toast.show({
      type: "success",
      text1: "Item added!",
      text2: `${newItem} has been added to your inventory.`,
    });
    setNewItem("");
  };

  const removeItem = async (itemName) => {
    const updatedFoodItems = foodItems.filter(
      (foodItem) => foodItem.name !== itemName,
    );
    setFoodItems(updatedFoodItems);

    await AsyncStorage.setItem(
      "food_items_array",
      JSON.stringify(updatedFoodItems),
    );
  };

  const handleRemoveSelected = () => {
    selected.forEach((itemName) => removeItem(itemName));
    setSelected([]);
  };

  const saveInventory = async () => {
    if (newlyAddedItems.length > 0) {
      console.log("Newly added items: ", newlyAddedItems);
      setIsLoading(true); // Start loading
      const systemPrompt = {
        role: "system",
        content: ADD_FOOD_PROMPT,
      };
      const userPrompt = {
        role: "user",
        content: newlyAddedItems.join("\n"),
      };

      const asyncFoodItemsResponse = await openai.chat.completions.create({
        model: "ft:gpt-3.5-turbo-0125:ounje:finalfoodinspector:9aubDZRg",
        temperature: 0.5,
        messages: [systemPrompt, userPrompt],
      });

      const [{ value: bloatedCheckItemsResponse }] = await Promise.allSettled([
        asyncFoodItemsResponse,
      ]);
      console.log(bloatedCheckItemsResponse);
      console.log(bloatedCheckItemsResponse.choices[0].message.content);
      const checkItemsResponse =
        bloatedCheckItemsResponse.choices[0].message.content;

      // Process the OpenAI response to convert the plain text to an array of strings
      const parsedItems = checkItemsResponse
        .slice(1, -1) // Remove the surrounding square brackets
        .split(",") // Split by comma
        .map((item) => item.trim()); // Trim each item

      const spoonacularResponse = await parse_ingredients(parsedItems);

      const actualFoodItems = spoonacularResponse.map((item) => ({
        name: item.name,
        spoonacular_id: item.id,
      }));

      const updatedFoodItems = [...foodItems, ...actualFoodItems];
      setFoodItems(updatedFoodItems);
      await AsyncStorage.setItem(
        "food_items_array",
        JSON.stringify(updatedFoodItems),
      );

      setNewlyAddedItems([]);
      setIsLoading(false); // Stop loading
      Toast.show({
        type: "success",
        text1: "Inventory saved!",
        text2: "Your inventory has been successfully updated.",
      });
      navigation.navigate("Home");
    } else {
      Alert.alert("No items to save", "Please add items before saving.");
    }
  };

  const handleAddImage = async () => {
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
            const imageUri = result.assets[0].uri;
            setInventoryImages((prevUris) => [...prevUris, imageUri]);
          }
        } else if (buttonIndex === 2) {
          let result = await ImagePicker.launchImageLibraryAsync({
            mediaTypes: ImagePicker.MediaTypeOptions.All,
            allowsEditing: true,
            aspect: [4, 3],
            quality: 1,
          });

          if (!result.canceled) {
            const imageUri = result.assets[0].uri;
            setInventoryImages((prevUris) => [...prevUris, imageUri]);
          }
        }
      },
    );
  };

  const handleReplaceImage = async (index) => {
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
            const imageUri = result.assets[0].uri;
            const base64Image = await convertImageToBase64(imageUri);

            // Replace the image in the array
            const updatedImages = [...inventoryImages];
            updatedImages[index] = imageUri;
            setInventoryImages(updatedImages);

            // Optionally, you can send the image for processing
            setIsLoading(true);
            await sendImages([base64Image]);
            setIsLoading(false);
            Alert.alert("Success", "Image has been replaced.");

            // Close the modal
            setModalVisible(false);
          }
        } else if (buttonIndex === 2) {
          let result = await ImagePicker.launchImageLibraryAsync({
            mediaTypes: ImagePicker.MediaTypeOptions.All,
            allowsEditing: true,
            aspect: [4, 3],
            quality: 1,
          });

          if (!result.canceled) {
            const imageUri = result.assets[0].uri;
            const base64Image = await convertImageToBase64(imageUri);

            // Replace the image in the array
            const updatedImages = [...inventoryImages];
            updatedImages[index] = imageUri;
            setInventoryImages(updatedImages);

            // Optionally, you can send the image for processing
            setIsLoading(true);
            await sendImages([base64Image]);
            setIsLoading(false);
            Alert.alert("Success", "Image has been replaced.");

            // Close the modal
            setModalVisible(false);
          }
        }
      },
    );
  };

  return (
    <View style={styles.container}>
      {isLoading && (
        <View style={styles.loader}>
          <ActivityIndicator size="large" color="#38F096" />
        </View>
      )}
      <ScrollView contentContainerStyle={styles.scrollViewContent}>
        <View style={styles.imageSection}>
          <View style={styles.imageContainer}>
            {inventoryImages.length === 0 ? (
              <TouchableOpacity
                style={styles.addImageButton}
                onPress={handleAddImage}
              >
                <Image
                  source={camera}
                  style={{ width: 100, height: 100, margin: 1 }}
                />
              </TouchableOpacity>
            ) : (
              inventoryImages.map((imageUrl, index) => (
                <TouchableOpacity
                  key={index}
                  onPress={() => {
                    setSelectedImage(imageUrl);
                    setModalVisible(true);
                  }}
                >
                  <Image source={{ uri: imageUrl }} style={styles.image} />
                </TouchableOpacity>
              ))
            )}
          </View>
        </View>

        <Modal
          animationType="slide"
          transparent={true}
          visible={modalVisible}
          onRequestClose={() => setModalVisible(false)}
        >
          <View style={styles.modalOverlay}>
            <TouchableOpacity
              style={styles.close}
              onPress={() => setModalVisible(false)}
            >
              <AntDesign name="closecircle" size={30} color="white" />
            </TouchableOpacity>
            <View style={styles.modalView}>
              <Image
                source={{ uri: selectedImage }}
                style={styles.modalImage}
              />
              <TouchableOpacity
                style={styles.replaceButton}
                onPress={() =>
                  handleReplaceImage(inventoryImages.indexOf(selectedImage))
                }
              >
                <Text style={styles.buttonText}>Replace Image</Text>
              </TouchableOpacity>
            </View>
          </View>
        </Modal>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Add New Food Item</Text>
          <View style={styles.inputContainer}>
            <TextInput
              style={styles.input}
              placeholder="Enter your food item"
              placeholderTextColor="gray"
              autoCapitalize="none"
              maxLength={50}
              value={newItem}
              onChangeText={setNewItem}
            />
            <TouchableOpacity style={styles.addButton} onPress={addNewItem}>
              <Text style={styles.buttonText}>Add</Text>
            </TouchableOpacity>
          </View>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Remove Food Items</Text>
          <MultipleSelectList
            showSelectedNumber
            setSelected={setSelected}
            selectedTextStyle={styles.selectedTextStyle}
            dropdownTextStyles={styles.dropdownTextStyles}
            data={foodItems.map((item) => ({
              key: item.name,
              value: item.name,
            }))}
            save="value"
            maxHeight={900}
            placeholder="Select items"
            placeholderStyles={styles.placeholderStyles}
            arrowicon={
              <FontAwesome5 name="chevron-down" size={12} color="white" />
            }
            searchicon={<FontAwesome5 name="search" size={12} color="white" />}
            search={false}
            boxStyles={styles.selectListBoxStyles}
            label="Select Food Items to Remove"
            labelStyles={styles.labelStyles}
            badgeStyles={styles.badgeStyles}
          />
          <TouchableOpacity
            style={styles.removeButton}
            onPress={handleRemoveSelected}
          >
            <Text style={styles.buttonText}>Remove</Text>
          </TouchableOpacity>
        </View>

        <View style={styles.centeredView}>
          <TouchableOpacity style={styles.saveButton} onPress={saveInventory}>
            <Text style={styles.saveButtonText}>Save Inventory</Text>
          </TouchableOpacity>
        </View>
      </ScrollView>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#121212",
    padding: 20,
  },
  scrollViewContent: {
    flexGrow: 1,
  },
  imageSection: {
    marginTop: 20,
  },
  imageContainer: {
    flexDirection: "row",
    flexWrap: "wrap",
    justifyContent: "center",
    alignItems: "center",
    marginBottom: 15,
    padding: 15,
  },
  image: {
    margin: 10,
    borderRadius: 10,
    width: 100,
    height: 100,
  },
  addImageButton: {
    borderRadius: 10,
    padding: 20,
    alignItems: "center",
    justifyContent: "center",
  },
  addImageText: {
    color: "#fff",
    fontSize: 18,
    fontWeight: "bold",
  },
  modalOverlay: {
    flex: 1,
    backgroundColor: "rgba(0, 0, 0, 0.8)",
    justifyContent: "center",
    alignItems: "center",
  },
  close: {
    position: "absolute",
    top: 50,
    right: 20,
  },
  modalView: {
    backgroundColor: "#222",
    borderRadius: 10,
    padding: 20,
    alignItems: "center",
  },
  modalImage: {
    width: 300,
    height: 300,
    resizeMode: "contain",
  },
  replaceButton: {
    marginTop: 10,
    backgroundColor: "#282C35",
    borderRadius: 10,
    padding: 10,
    alignItems: "center",
  },
  card: {
    backgroundColor: "#1f1f1f",
    borderRadius: 10,
    padding: 20,
    marginBottom: 20,
  },
  cardTitle: {
    color: "#fff",
    fontSize: 18,
    fontWeight: "bold",
    marginBottom: 10,
  },
  inputContainer: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 10,
  },
  input: {
    flex: 1,
    height: 50,
    borderColor: "white",
    borderWidth: 1,
    padding: 10,
    borderRadius: 10,
    color: "#fff",
    backgroundColor: "#333",
  },
  addButton: {
    marginLeft: 10,
    backgroundColor: "#282C35",
    borderRadius: 5,
    padding: 10,
  },
  buttonText: {
    color: "white",
    fontWeight: "bold",
  },
  selectedTextStyle: {
    color: "#32cd32",
    fontSize: 16,
  },
  dropdownTextStyles: {
    color: "#fff",
  },
  placeholderStyles: {
    color: "#fff",
  },
  selectListBoxStyles: {
    borderColor: "white",
    borderWidth: 1,
    borderRadius: 10,
    backgroundColor: "#333",
  },
  labelStyles: {
    color: "#fff",
    fontSize: 14,
    fontWeight: "bold",
  },
  badgeStyles: {
    backgroundColor: "#9b111e",
  },
  removeButton: {
    marginTop: 10,
    backgroundColor: "#282C35",
    borderRadius: 10,
    padding: 10,
    alignItems: "center",
  },
  centeredView: {
    alignItems: "center",
    marginTop: 20,
  },
  saveButton: {
    width: 200,
    height: 50,
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
    marginBottom: 20,
  },
  saveButtonText: {
    color: "#38F096",
    fontWeight: "bold",
    fontSize: 18,
  },
  itemText: {
    color: "#fff",
    fontSize: 16,
    marginVertical: 2,
  },
  loader: {
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "rgba(0, 0, 0, 0.5)",
    zIndex: 1,
  },
});

export default Inventory;
