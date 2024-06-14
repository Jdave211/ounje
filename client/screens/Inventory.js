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
} from "react-native";
import { FontAwesome5, AntDesign } from "@expo/vector-icons";
import { MultipleSelectList } from "../components/MultipleSelectList";
import { supabase } from "../utils/supabase";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { useNavigation } from "@react-navigation/native";
import Toast from "react-native-toast-message";

const Inventory = () => {
  const navigation = useNavigation();
  const [selected, setSelected] = useState([]);
  const [modalVisible, setModalVisible] = useState(false);
  const [selectedImage, setSelectedImage] = useState(null);
  const [foodItems, setFoodItems] = useState([]);
  const [inventoryImages, setInventoryImages] = useState([]);
  const [userId, setUserId] = useState(null);
  const [newItem, setNewItem] = useState("");

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

  const addNewItem = async () => {
    if (newItem.trim() === "") {
      Alert.alert("Error", "Please enter a valid item name.");
      return;
    }

    const updatedFoodItems = [
      ...foodItems,
      { name: newItem, spoonacular_id: Date.now(), image: "" },
    ];
    setFoodItems(updatedFoodItems);
    setNewItem("");
    Toast.show({
      type: "success",
      text1: "Item added!",
      text2: `${newItem} has been added to your inventory.`,
    });
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
    await AsyncStorage.setItem("food_items_array", JSON.stringify(foodItems));
    Alert.alert("Your inventory has been saved!");
    navigation.navigate("Home");
  };

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.scrollViewContent}>
        <View style={styles.imageSection}>
          <View style={styles.imageContainer}>
            {inventoryImages.map((imageUrl, index) => (
              <TouchableOpacity
                key={index}
                onPress={() => {
                  setSelectedImage(imageUrl);
                  setModalVisible(true);
                }}
              >
                <Image source={{ uri: imageUrl }} style={styles.image} />
              </TouchableOpacity>
            ))}
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
            </View>
          </View>
        </Modal>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Add New Food Item</Text>
          <View style={styles.inputContainer}>
            <TextInput
              style={styles.input}
              placeholder="Enter item name"
              placeholderTextColor="gray"
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
  },
  modalImage: {
    width: 300,
    height: 300,
    resizeMode: "contain",
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
    borderColor: "#32cd32",
    borderWidth: 1,
    padding: 10,
    borderRadius: 10,
    color: "#fff",
    backgroundColor: "#333",
  },
  addButton: {
    marginLeft: 10,
    backgroundColor: "#32cd32",
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
    borderColor: "#9b111e",
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
    backgroundColor: "#9b111e",
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
    backgroundColor: "#32cd32",
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
  },
  saveButtonText: {
    color: "#fff",
    fontWeight: "bold",
  },
});

export default Inventory;
