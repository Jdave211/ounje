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

const Inventory = () => {
  const navigation = useNavigation();
  const [selected, setSelected] = useState([]);
  const [modalVisible, setModalVisible] = useState(false);
  const [selectedImage, setSelectedImage] = useState(null);
  const [foodItemsArray, setFoodItemsArray] = useState([]);
  const [inventoryImages, setInventoryImages] = useState([]);
  const [userId, setUserId] = useState(null);
  const [newItem, setNewItem] = useState("");

  useEffect(() => {
    const fetchInitialData = async () => {
      const retrievedUserId = await AsyncStorage.getItem("user_id");
      setUserId(retrievedUserId);

      const retrievedArrayText = await AsyncStorage.getItem("food_items_array");
      const retrievedFoodItemsArray = JSON.parse(retrievedArrayText || "[]");
      setFoodItemsArray(retrievedFoodItemsArray);

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
    console.log("fooditems", foodItemsArray);
    if (newItem.trim() === "") {
      Alert.alert("Error", "Please enter a valid item name.");
      return;
    }

    const updatedFoodItemsArray = [
      ...foodItemsArray,
      { key: newItem, value: newItem },
    ];
    setFoodItemsArray(updatedFoodItemsArray);
    setNewItem("");

    await AsyncStorage.setItem(
      "food_items_array",
      JSON.stringify(updatedFoodItemsArray),
    );
  };

  const removeItem = async (item) => {
    const updatedFoodItemsArray = foodItemsArray.filter(
      (foodItem) => foodItem.key !== item,
    );
    setFoodItemsArray(updatedFoodItemsArray);

    await AsyncStorage.setItem(
      "food_items_array",
      JSON.stringify(updatedFoodItemsArray),
    );
  };

  const saveInventory = async () => {
    if (userId) {
      const { data, error } = await supabase
        .from("inventory")
        .update({ items: foodItemsArray })
        .eq("user_id", userId);

      if (error) {
        Alert.alert("Error", "Failed to save inventory.");
      } else {
        Alert.alert("Success", "Inventory saved successfully.");
      }
    }
  };

  return (
    <View style={styles.container}>
      <ScrollView
        contentContainerStyle={{ flexGrow: 1, justifyContent: "space-between" }}
      >
        <View>
          <View style={{ flex: 0.2 }}>
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

            <Modal
              animationType="slide"
              transparent={false}
              visible={modalVisible}
              onRequestClose={() => setModalVisible(false)}
            >
              <TouchableOpacity
                style={styles.close}
                onPress={() => setModalVisible(false)}
              >
                <AntDesign name="closecircle" size={30} color="white" />
              </TouchableOpacity>
              <View style={[styles.centeredView, styles.modalView]}>
                <Image
                  source={{ uri: selectedImage }}
                  style={styles.modalImage}
                />
              </View>
            </Modal>
          </View>

          <View style={styles.inputContainer}>
            <TextInput
              style={styles.input}
              placeholder="Add new items here"
              placeholderTextColor="gray"
              value={newItem}
              onChangeText={setNewItem}
            />
            <TouchableOpacity style={styles.addButton} onPress={addNewItem}>
              <Text style={styles.buttonText}> Add </Text>
            </TouchableOpacity>
          </View>

          <View style={styles.inputContainer}>
            <View style={{ flex: 1 }}>
              <MultipleSelectList
                showSelectedNumber
                setSelected={setSelected}
                selectedTextStyle={styles.selectedTextStyle}
                dropdownTextStyles={{ color: "white" }}
                data={foodItemsArray}
                save="value"
                maxHeight={900}
                placeholder="Select items"
                placeholderStyles={{ color: "white" }}
                arrowicon={
                  <FontAwesome5 name="chevron-down" size={12} color="white" />
                }
                searchicon={
                  <FontAwesome5 name="search" size={12} color="white" />
                }
                search={false}
                boxStyles={{
                  marginTop: 10,
                  marginBottom: 10,
                  borderColor: "red",
                  borderWidth: 2,
                  width: "100%",
                }}
                label="Select Food Items to Remove"
                labelStyles={{
                  color: "gray",
                  fontSize: 14,
                  fontWeight: "bold",
                }}
                badgeStyles={{ backgroundColor: "red" }}
              />
            </View>
          </View>
          <TouchableOpacity
            style={styles.removeButton}
            onPress={() => selected.forEach(removeItem)}
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
    backgroundColor: "black",
  },
  overlay: {
    borderRadius: 10,
    padding: 10,
  },
  close: {
    position: "absolute",
    top: 40,
    right: 20,
    zIndex: 1,
  },
  centeredView: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    marginTop: 22,
  },
  modalView: {
    backgroundColor: "black",
  },
  modalImage: {
    width: "100%",
    height: "100%",
    resizeMode: "contain",
  },
  selectedTextStyle: {
    color: "blue",
    fontSize: 16,
  },
  inputContainer: {
    display: "flex",
    marginTop: 30,
    paddingRight: 11,
    paddingLeft: 11,
    flexDirection: "row",
    alignItems: "center",
  },
  addButton: {
    marginLeft: 10,
    backgroundColor: "green",
    borderRadius: 5,
    padding: 10,
  },
  removeButton: {
    alignSelf: "flex-start", // Ensure the remove button stays static
    marginLeft: 10,
    backgroundColor: "#AE0618",
    borderRadius: 5,
    padding: 10,
    marginTop: 10,
  },
  buttonText: {
    color: "white",
    fontWeight: "bold",
  },
  saveButton: {
    width: 200,
    height: 50,
    backgroundColor: "#6b9080",
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
    marginTop: 20,
    marginBottom: 20,
  },
  saveButtonText: {
    color: "#fff",
    fontWeight: "bold",
  },
  imageContainer: {
    width: "100%",
    justifyContent: "space-evenly",
    alignItems: "center",
    flexDirection: "row",
    flexWrap: "wrap",
  },
  image: {
    margin: 10,
    borderRadius: 10,
    width: 100,
    height: 100,
  },
  centerItems: {
    display: "flex",
    flexDirection: "row",
    justifyContent: "center",
    alignItems: "center",
  },
  input: {
    borderWidth: 2,
    borderColor: "#32cd32",
    padding: 10,
    flex: 1,
    color: "white",
    borderRadius: 10,
    height: 55,
  },
});

export default Inventory;
