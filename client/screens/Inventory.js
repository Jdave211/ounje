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
  Dimensions,
  FlatList,
} from "react-native";
import { Button, Icon } from "react-native-elements";
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
import fridge from "../assets/fridge.png";
import pantry from "../assets/pantry.png";
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
import IngredientCard from "../components/IngredientCard";
import { T } from "ramda";
import AsyncStorage from "@react-native-async-storage/async-storage";
import GroceryList from "./Grocery/GroceryList";
import Pantry from "./Grocery/Pantry";

const screenWidth = Dimensions.get("window").width;
const screenHeight = Dimensions.get("window").height;

const Inventory = ({ route }) => {
  const groceryList = route.params?.groceryList;
  const [groceryListAdd, setgroceryListAdd] = useState();
 
  console.log("Grocery List: ", groceryList);
  console.log("Route params:", route.params);
  const navigation = useNavigation();
  const [selected, setSelected] = useState([]);
  const [modalVisible, setModalVisible] = useState(false);
  const [selectedImage, setSelectedImage] = useState(null);
  const [_inventoryImages, setInventoryImages] = useState([]);
  const [newItem, setNewItem] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [_foodItems, setFoodItems] = useState([]);
  const [notificationVisible, setNotificationVisible] = useState(false);
  const [selectedTab, setSelectedTab] = useState("Inventory");

  const userId = useAppStore((state) => state.user_id);
  const inventory = useAppStore((state) => state.inventory);
  const inventoryData = useAppStore((state) => state.inventory.data);
  const setUserId = useAppStore((state) => state.set_user_id);
  const getFoodItems = useAppStore((state) => state.inventory.getFoodItems);
  const getImages = useAppStore((state) => state.inventory.getImages);
  const setInventoryData = useAppStore(
    (state) => state.inventory.setInventoryData
  );

  const addManuallyAddedItems = useAppStore(
    (state) => state.inventory.addManuallyAddedItems
  );
  const replaceImageAndItsItems = useAppStore(
    (state) => state.inventory.replaceImageAndItsItems
  );
  const addImagesAndItems = useAppStore(
    (state) => state.inventory.addImagesAndItems
  );

  const [ImageConvertLoadng, setImageConvertLoadng] = useState(false);

  const foodItems = getFoodItems(); // Get food items from app store
  const inventoryImages = getImages(); // Get inventory images from app store

  console.log({ userId, name: "inventory", inventoryData }); // Log user ID and inventory data
  const { loading, convertImageToBase64, sendImages } = useImageProcessing(); // Image processing hook

  // Fetch inventory data using React Query
  const { refetch: refetchInventoryData } = useQuery(
    ["inventoryImages", userId],
    async () => fetchInventoryData(userId),
    { onSuccess: (inventoryData) => setInventoryData(inventoryData) } // Set inventory data on success
  );

  // Show authentication alert if user is not logged in
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
          onPress: () => setUserId(null), // Set user ID to null to prompt sign in
        },
      ],
      { cancelable: true }
    );
  };

  // Add new item to inventory
  const addNewItem = async () => {
    if (userId.startsWith("guest")) {
      showAuthAlert(); // Show authentication alert for guest users
      return;
    }

    const trimmedItem = newItem.trim().toLowerCase(); // Normalize case for comparison

    if (trimmedItem === "") {
      Alert.alert("Error", "Please enter a valid item name."); // Alert for empty item name
      return;
    }

    setIsLoading(true); // Start loading

    // Parse the new item input
    const newlyParsedFoodItems = await parse_ingredients([newItem]);
    console.log({ newlyParsedFoodItems });

    // Validate the parsed items
    if (!newlyParsedFoodItems || newlyParsedFoodItems.length === 0) {
      Alert.alert("Error", "Please add only food items."); // Alert if no valid food items are found
      setIsLoading(false); // Stop loading
      return;
    }

    // Check if any item has an undefined spoonacular_id
    const invalidItems = newlyParsedFoodItems.filter(
      (item) => !item.spoonacular_id
    );
    if (invalidItems.length > 0) {
      Alert.alert("Error", "Please add only valid food items.");
      setIsLoading(false);
      return;
    }

    // Check for duplicates by item name or spoonacular_id
    const existingItemNames = new Set(
      foodItems.map((item) => item.name.toLowerCase())
    );
    const existingItemIds = new Set(
      foodItems.map((item) => item.spoonacular_id)
    ); // Use spoonacular_id here

    // Check for duplicates by both name and ID (if spoonacular_id is available)
    const nonDuplicateItems = newlyParsedFoodItems.filter(
      (item) =>
        (!item.spoonacular_id || !existingItemIds.has(item.spoonacular_id)) &&
        !existingItemNames.has(item.name.toLowerCase())
    );

    if (nonDuplicateItems.length === 0) {
      Alert.alert("Duplicate Item", "This item is already in your inventory.");
      setIsLoading(false); // Stop loading
      return;
    }

    const newly_stored_items = await storeNewFoodItems(nonDuplicateItems);

    await addInventoryItem(
      userId,
      newly_stored_items.map(({ spoonacular_id }) => spoonacular_id) // Use spoonacular_id here
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

  useFocusEffect(
    React.useCallback(() => {
      if (groceryList) {
        setgroceryListAdd(groceryList);
        console.log("Conversation ID set: ", groceryList);
      }
    }, [groceryList])
  );

  const handleRemoveGrocery = async (groceryList) => {
    if (userId.startsWith("guest")) {
      showAuthAlert();
      return;
    }
const updatedList = groceryListAdd.filter(item => item.id !== groceryList.id);
    setgroceryListAdd(updatedList);

     // Update AsyncStorage
     try {
      await AsyncStorage.setItem('groceryList', JSON.stringify(updatedList));
      Toast.show({
        type: "success",
        text1: "Item removed!",
        text2: `${groceryList?.name} has been removed from your grocery.`,
        onHide: () => setNotificationVisible(true), // Show the notification after the toast
      });
    } catch (error) {
      console.error('Failed to update grocery list in AsyncStorage', error);
    }
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

    Alert.alert(
      "Select Photo",
      "Choose an option:",
      [
        {
          text: "Cancel",
          style: "cancel",
        },
        {
          text: "Take Photo",
          onPress: async () => {
            const result = await ImagePicker.launchCameraAsync({
              mediaTypes: ImagePicker.MediaTypeOptions.All,
              allowsEditing: true,
              aspect: [4, 3],
              quality: 1,
            });
            handleImageSelection(result);
          },
        },
        {
          text: "Choose from Library",
          onPress: async () => {
            const result = await ImagePicker.launchImageLibraryAsync({
              mediaTypes: ImagePicker.MediaTypeOptions.All,
              allowsEditing: true,
              aspect: [4, 3],
              quality: 1,
            });
            handleImageSelection(result);
          },
        },
      ],
      { cancelable: true }
    );
  };

  const handleReplaceImage = async (index) => {
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

    Alert.alert(
      "Select Photo",
      "Choose an option:",
      [
        {
          text: "Cancel",
          style: "cancel",
        },
        {
          text: "Take Photo",
          onPress: async () => {
            const result = await ImagePicker.launchCameraAsync({
              mediaTypes: ImagePicker.MediaTypeOptions.All,
              allowsEditing: true,
              aspect: [4, 3],
              quality: 1,
            });
            handleImageSelection(result, index);
          },
        },
        {
          text: "Choose from Library",
          onPress: async () => {
            const result = await ImagePicker.launchImageLibraryAsync({
              mediaTypes: ImagePicker.MediaTypeOptions.All,
              allowsEditing: true,
              aspect: [4, 3],
              quality: 1,
            });
            handleImageSelection(result, index);
          },
        },
      ],
      { cancelable: true }
    );
  };

  const handleImageSelection = async (result, index) => {
    if (!result.canceled) {
      const imageUri = result.assets[0].uri;
      const base64Image = await convertImageToBase64(imageUri);

      setIsLoading(true);
      await sendImages([base64Image]);
      refetchInventoryData();
      setIsLoading(false);

      const message =
        index !== undefined
          ? "Image has been replaced."
          : "Image has been added.";
      Alert.alert("Success", message);

      if (index !== undefined) {
        setModalVisible(false); // Close modal if replacing an image
      }
    }
  };

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.headerText}>Inventory</Text>
        <Text style={styles.headerSubtext}>Your inventory & grocery list</Text>
      </View>

      <View style={styles.segmentedControl}>
        <TouchableOpacity
          style={[
            styles.segmentButton,
            selectedTab === "Inventory" && styles.segmentButtonSelected,
          ]}
          onPress={() => setSelectedTab("Inventory")}
        >
          <Text
            style={[
              styles.segmentButtonText,
              selectedTab === "Inventory" && styles.segmentButtonTextSelected,
            ]}
          >
            Inventory
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[
            styles.segmentButton,
            selectedTab === "GroceryList" && styles.segmentButtonSelected,
          ]}
          onPress={() => setSelectedTab("GroceryList")}
        >
          <Text
            style={[
              styles.segmentButtonText,
              selectedTab === "GroceryList" && styles.segmentButtonTextSelected,
            ]}
          >
            Grocery List
          </Text>
        </TouchableOpacity>
      </View>

      {isLoading && (
        <View style={styles.loader}>
          <ActivityIndicator size="large" color="#38F096" />
        </View>
      )}
      <ScrollView
        showsVerticalScrollIndicator={false}
        contentContainerStyle={styles.scrollViewContent}
      >
        {selectedTab === "Inventory" ? (
          <>
            <View style={styles.imageSection}>
              <View style={styles.imageContainer}>
                <Text style={styles.imageTitle}>Fridge</Text>
                {inventoryImages?.length === 0 ? (
                  <TouchableOpacity
                    style={styles.addImageButton}
                    onPress={handleAddImage}
                  >
                    <Image
                      source={fridge}
                      style={styles.image} // Responsive width and height
                    />
                    <View style={styles.overlay}>
                      <Text style={styles.overlayTextAdd}>Tap to add+</Text>
                    </View>
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
              <View style={styles.imageContainer}>
                <Pantry />
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
                    onPress={() => {
                      handleReplaceImage(
                        inventoryImages.indexOf(selectedImage)
                      );
                      setModalVisible(false);
                    }}
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
              <View style={styles.centeredContainer}>
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
                    <View
                      key={i}
                      style={{ width: 90, marginBottom: 10, marginRight: 10 }}
                    >
                      <IngredientCard
                        key={i}
                        name={item?.name}
                        image={`https://img.spoonacular.com/ingredients_100x100/${item?.image}`}
                        showCancelButton={true}
                        onCancel={() => handleRemoveSelected(item)}
                      />
                    </View>
                  ))
                )}
              </View>
            </View>
          </>
        ) : (

          <View>

            <View>

              <GroceryList/>
            </View>
          <View>
            <Text style={styles.cardTitle}>Grocery Icon</Text>

            <View style={styles.card}>
              <Text style={styles.cardTitle}>Grocery List</Text>
              <View style={styles.centeredContainer}>

              {/* Conditionally render a message if the groceryList is empty */}
              {!groceryList || groceryList.length === 0 ? (
                <Text style={styles.warning}>
                  No items in your grocery list yet.
                </Text>
              ) : (
                
                
                groceryListAdd.map((item, i) => (
                  <View
                    key={i}
                    style={{ width: 90, marginBottom: 10, marginRight: 10 }}
                  >
                    <IngredientCard
                      key={i}
                      name={item?.name}
                      image={`https://img.spoonacular.com/ingredients_100x100/${item?.image}`}
                      showCancelButton={true}
                      onCancel={() => handleRemoveGrocery(item)}
                    />
                  </View>
                ))
              )}
            </View>
            </View>
          </View>
          </View>
        )}
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
    padding: Dimensions.get("window").width * 0.03,
  },
  scrollViewContent: {
    flexGrow: 1,
    justifyContent: "center",
    padding: 8,
  },
  header: {
    justifyContent: "flex-start",
    alignItems: "flex-start",
    marginBottom: Dimensions.get("window").height * 0.05,
    marginTop: Dimensions.get("window").height * 0.1,
    marginLeft: Dimensions.get("window").width * 0.03,
  },
  headerText: {
    color: "#fff",
    fontSize: 25,
    fontWeight: "bold",
  },
  headerSubtext: {
    color: "gray",
    fontSize: 16,
    marginTop: 5,
  },
  segmentedControl: {
    flexDirection: "row",
    alignSelf: "stretch",
    marginBottom: 20,
    borderBottomWidth: 1,
    borderBottomColor: "#282C35",
  },
  segmentButton: {
    flex: 1,
    paddingVertical: 10,
    alignItems: "center",
  },
  segmentButtonSelected: {
    borderBottomWidth: 2,
    borderBottomColor: "gray",
  },
  segmentButtonText: {
    color: "gray",
    fontSize: 16,
  },
  segmentButtonTextSelected: {
    color: "white",
    fontWeight: "bold",
  },
  warning: {
    color: "white",
    marginBottom: 10,
    fontWeight: "bold",
    fontSize: screenWidth * 0.035, // Responsive font size
    textAlign: "center",
  },
  imageSection: {
    flexDirection: "row",
    justifyContent: "space-around", // Adjust as necessary to space the containers
    alignItems: "flex-start",
  },
  imageContainer: {
    flexDirection: "column",
    alignItems: "center", // Center items in the column
    marginBottom: 15,
    padding: 15,
  },
  imageTitle: {
    color: "#fff",
    fontSize: screenWidth * 0.04, // Responsive font size
    fontWeight: "bold",
    textAlign: "center",
    marginBottom: 6,
  },
  imageWrapper: {
    position: "relative",
    margin: 10,
  },
  image: {
    borderRadius: 10,
    width: screenWidth * 0.25, // Responsive width
    height: screenWidth * 0.25, // Responsive height
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
    fontSize: screenWidth * 0.03, // Responsive font size
  },
  overlayTextAdd: {
    color: "#fff",
    fontSize: screenWidth * 0.03, // Responsive font size
    fontWeight: "bold",
  },
  addImageButton: {
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center", // Removed any padding that would extend the overlay beyond the image
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
    width: screenWidth * 0.75, // Responsive width
    height: screenWidth * 0.75, // Responsive height
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
    fontSize: screenWidth * 0.045, // Responsive font size
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
  centeredContainer: {
    flexDirection: "row",
    flexWrap: "wrap",
    justifyContent: "center",
    alignItems: "center",
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
    width: screenWidth * 0.08, // Responsive width
    height: screenWidth * 0.08, // Responsive height
    borderRadius: 10,
    marginRight: 10,
  },
  ingredientTextContainer: {
    flex: 1,
    flexDirection: "column",
    alignItems: "flex-start",
  },
  ingredientText: {
    fontSize: screenWidth * 0.04, // Responsive font size
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
    fontSize: screenWidth * 0.035, // Responsive font size
  },
  ingredientText: {
    fontSize: 14,
    fontWeight: "600",
    color: "white",
    textAlign: "center",
  },
});

export default Inventory;
