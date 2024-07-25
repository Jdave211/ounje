import React, { useState } from "react";
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
import { FontAwesome5, AntDesign, MaterialIcons } from "@expo/vector-icons";
import { MultipleSelectList } from "../components/MultipleSelectList";
import {
  supabase,
  fetchImageSignedUrl,
  fetchFoodItems,
  storeNewFoodItems,
} from "../utils/supabase";
import { useNavigation, useFocusEffect } from "@react-navigation/native";
import Toast from "react-native-toast-message";
import * as ImagePicker from "expo-image-picker";
import camera from "../assets/camera_icon.png";
import { parse_ingredients } from "../utils/spoonacular";
import useImageProcessing from "../hooks/useImageProcessing";
import { useAppStore } from "../stores/app-store";
import { useQuery } from "react-query";
import axios from "axios";
import {
  addInventoryItem,
  fetchInventoryData,
  removeInventoryItems,
} from "../utils/server-api";
import { entitle } from "../utils/helpers";
import Empty from "../components/Empty";

const Inventory = () => {
  const navigation = useNavigation();
  const [selected, setSelected] = useState([]);
  const [modalVisible, setModalVisible] = useState(false);
  const [selectedImage, setSelectedImage] = useState(null);
  const [_inventoryImages, setInventoryImages] = useState([]);
  const [newItem, setNewItem] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [_foodItems, setFoodItems] = useState([]);
  const [notificationVisible, setNotificationVisible] = useState(false);

  const userId = useAppStore((state) => state.user_id);
<<<<<<< Updated upstream
  const inventory = useAppStore((state) => state.inventory);

  const inventoryData = useAppStore((state) => state.inventory.data);
=======
  const setUserId = useAppStore((state) => state.set_user_id);
>>>>>>> Stashed changes
  const getFoodItems = useAppStore((state) => state.inventory.getFoodItems);
  const getImages = useAppStore((state) => state.inventory.getImages);
  const setInventoryData = useAppStore(
    (state) => state.inventory.setInventoryData,
  );

  const addManuallyAddedItems = useAppStore(
    (state) => state.inventory.addManuallyAddedItems,
  );
  const replaceImageAndItsItems = useAppStore(
    (state) => state.inventory.replaceImageAndItsItems,
  );
  const addImagesAndItems = useAppStore(
    (state) => state.inventory.addImagesAndItems,
  );

  const foodItems = getFoodItems();
  const inventoryImages = getImages();

  console.log({ userId, name: "inventory", inventoryData });
  const { loading, convertImageToBase64, sendImages } = useImageProcessing();

  const { refetch: refetchInventoryData } = useQuery(
    ["inventoryImages", userId],
    async () => fetchInventoryData(userId),
    { onSuccess: (inventoryData) => setInventoryData(inventoryData) },
  );

  const showAuthAlert = () => {
    Alert.alert(
      "Authentication Required",
      "You need to be logged in to create your virtual inventory.",
      [
        {
          text: "Cancel",
          style: "cancel",
        },
        {
          text: "Sign In / Sign Up",
          onPress: () => setUserId(null),
        },
      ],
      { cancelable: true },
    );
  };

  const addNewItem = async () => {
<<<<<<< Updated upstream
=======
    if (userId.startsWith("guest")) {
      showAuthAlert();
      return;
    }

    if (foodItems.length >= 100) {
      Alert.alert(
        "Premium Feature",
        "You have reached the maximum limit of 15 items. Please upgrade to premium to add more items.",
        [
          {
            text: "Go Premium",
            onPress: () => navigation.navigate("PremiumSubscription"),
          },
          { text: "Cancel", style: "cancel" },
        ],
      );
      return;
    }

>>>>>>> Stashed changes
    if (newItem.trim() === "") {
      Alert.alert("Error", "Please enter a valid item name.");
      return;
    }

    setIsLoading(true); // Start loading
    const newlyParsedFoodItems = await parse_ingredients([newItem]);

    if (!newlyParsedFoodItems || newlyParsedFoodItems.length === 0) {
      Alert.alert("Error", "Please add only food items.");
      setIsLoading(false); // Stop loading
      return;
    }

    const newly_stored_items = await storeNewFoodItems(newlyParsedFoodItems);

    await addInventoryItem(
      userId,
      newly_stored_items.map(({ id }) => id),
    );

    addManuallyAddedItems(newly_stored_items);

    setNewItem("");
    setIsLoading(false); // Stop loading

    Toast.show({
      type: "success",
      text1: "Item added!",
      text2: `${newItem} has been added to your inventory.`,
      onHide: () => setNotificationVisible(true), // Show the notification after the toast
    });
  };

  const handleRemoveSelected = async (food_item) => {
    if (userId.startsWith("guest")) {
      showAuthAlert();
      return;
    }

    await removeInventoryItems(userId, [food_item.id]);
    refetchInventoryData();

    Toast.show({
      type: "success",
      text1: "Item removed!",
      text2: `${food_item.name} has been removed from your inventory.`,
      onHide: () => setNotificationVisible(true), // Show the notification after the toast
    });
  };

  const handleAddImage = async () => {
    if (userId.startsWith("guest")) {
      showAuthAlert();
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
        if (buttonIndex === 1 || buttonIndex === 2) {
          let result;
          if (buttonIndex === 1) {
            result = await ImagePicker.launchCameraAsync({
              mediaTypes: ImagePicker.MediaTypeOptions.All,
              allowsEditing: true,
              aspect: [4, 3],
              quality: 1,
            });
          } else {
            result = await ImagePicker.launchImageLibraryAsync({
              mediaTypes: ImagePicker.MediaTypeOptions.All,
              allowsEditing: true,
              aspect: [4, 3],
              quality: 1,
            });
          }

          if (!result.canceled) {
            const imageUri = result.assets[0].uri;
            setInventoryImages((prevUris) => [...prevUris, imageUri]);
            const base64Image = await convertImageToBase64(imageUri);
            setIsLoading(true);
            await sendImages([base64Image]);
            refetchInventoryData();
            setIsLoading(false);
            Alert.alert("Success", "Image has been Added.");
          }
        }
      },
    );
  };

<<<<<<< Updated upstream
  const handleReplaceImage = async (index) => {
=======
  const handleReplaceImage = async () => {
    if (userId.startsWith("guest")) {
      showAuthAlert();
      return;
    }

>>>>>>> Stashed changes
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
        if (buttonIndex === 1 || buttonIndex === 2) {
          let result;

          if (buttonIndex === 1) {
            result = await ImagePicker.launchCameraAsync({
              mediaTypes: ImagePicker.MediaTypeOptions.All,
              allowsEditing: true,
              aspect: [4, 3],
              quality: 1,
            });
          } else {
            result = await ImagePicker.launchImageLibraryAsync({
              mediaTypes: ImagePicker.MediaTypeOptions.All,
              allowsEditing: true,
              aspect: [4, 3],
              quality: 1,
            });
          }

          if (!result.canceled) {
            const imageUri = result.assets[0].uri;
            const base64Image = await convertImageToBase64(imageUri);

            setIsLoading(true);
            await sendImages([base64Image]);
            refetchInventoryData();
            setIsLoading(false);
            Alert.alert("Success", "Image has been replaced.");

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
            {inventoryImages?.length === 0 ? (
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
                  style={styles.imageWrapper}
                >
                  <Image source={{ uri: imageUrl }} style={styles.image} />
                  <View style={styles.overlay}>
                    <Text style={styles.overlayText}>Tap to replace</Text>
                  </View>
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
          <Text style={styles.cardTitle}>Virtual Inventory</Text>
          {foodItems && foodItems.length === 0 ? (
            <View
              style={{
                flex: 2,
                justifyContent: "center",
                alignContent: "center",
              }}
            >
              <Empty />
              <Text style={styles.warning}>
                Your inventory is empty. Add some items to get started.
              </Text>
            </View>
          ) : (
            foodItems.map((item, i) => (
              <View key={i} style={styles.ingredient}>
                <Image
                  style={styles.ingredientImage}
                  source={{
                    uri: `https://img.spoonacular.com/ingredients_100x100/${item.image}`,
                  }}
                />
                <View style={styles.ingredientTextContainer}>
                  <Text style={styles.ingredientText}>
                    {item.name && entitle(item.name)}
                  </Text>
                </View>

                <TouchableOpacity
                  style={styles.removeButton}
                  onPress={() => handleRemoveSelected(item)}
                >
                  <MaterialIcons name="delete" size={15} color="white" />
                </TouchableOpacity>
              </View>
            ))
          )}
        </View>
      </ScrollView>
      {notificationVisible && (
        <TouchableOpacity
          style={styles.notification}
          onPress={() => {
            setNotificationVisible(false);
            navigation.navigate("Home"); // Adjust the route name as needed
          }}
        >
          <Text style={styles.notificationText}>
            Go to{" "}
            <Text
              style={{
                fontWeight: "bold",
                fontStyle: "italic",
              }}
            >
              Home{" "}
            </Text>
            to generate recipes
          </Text>
        </TouchableOpacity>
      )}
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
  warning: {
    color: "white",
    marginBottom: 10,
    fontWeight: "bold",
    fontSize: 14,
    textAlign: "center",
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
  imageWrapper: {
    position: "relative",
    margin: 10,
  },
  image: {
    borderRadius: 10,
    width: 100,
    height: 100,
  },
  overlay: {
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: "rgba(0, 0, 0, 0.5)",
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
  },
  overlayText: {
    color: "#fff",
    fontSize: 12,
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
    color: "gray",
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
  ingredient: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingVertical: 10,
  },
  ingredientImage: {
    width: 30,
    height: 30,
    borderRadius: 10,
    marginRight: 10,
  },
  ingredientTextContainer: {
    flex: 1,
    flexDirection: "column",
    alignItems: "flex-start",
  },
  ingredientText: {
    fontSize: 16,
    color: "white",
  },
  notification: {
    position: "absolute",
    bottom: 20,
    left: 20,
    right: 20,
    backgroundColor: "#1f1f1f", // Subtle background color to match the theme
    borderRadius: 5,
    padding: 10,
    alignItems: "center",
    justifyContent: "center",
    elevation: 2, // Slight elevation for subtle depth
  },
  notificationText: {
    color: "white",
    fontSize: 14,
  },
});

export default Inventory;
