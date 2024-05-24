import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  Image,
  TouchableOpacity,
  Modal,
  ImageBackground,
  TextInput,
  Alert,
} from "react-native";
import { FontAwesome5 } from "@expo/vector-icons";
import { AntDesign } from "@expo/vector-icons";
import { MultipleSelectList } from "../components/MultipleSelectList";
import { supabase } from "../utils/supabase";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { useNavigation } from "@react-navigation/native";

const Inventory = () => {
  const navigation = useNavigation();

  const [selected, setSelected] = useState([]);
  const [modalVisible, setModalVisible] = useState(false);
  const [selectedImage, setSelectedImage] = useState(null);
  const [food_items, setFoodItems] = useState([]);
  const [inventoryImages, setInventoryImages] = useState([]);
  const [user_id, setUserId] = useState(null);
  const [newItem, setNewItem] = useState("");

  useEffect(() => {
    const get_user_id = async () => {
      let retrieved_user_id = await AsyncStorage.getItem("user_id");
      setUserId(retrieved_user_id);
    };

    const fetch_food_items = async (userId) => {
      const { data: inventory, error } = await supabase
        .from("inventory")
        .select("food_items, images")
        .eq("user_id", userId)
        .single();

      if (error) {
        console.error("Error fetching food items:", error);
      } else if (inventory) {
        const foodItems = inventory.food_items ? JSON.parse(inventory.food_items) : [];
        setFoodItems(foodItems);
        console.log("Food Items:", foodItems);
        console.log("usestate:", food_items)
        fetch_inventory_images(inventory.images);
      } else {
        console.log("No inventory found for user_id:", userId);
      }
    };

    const fetch_inventory_images = async (images) => {
      const image_paths = images.map((image) =>
        image.replace("inventory_images/", "")
      );

      const { data: url_responses, error } = await supabase.storage
        .from("inventory_images")
        .createSignedUrls(image_paths, 60 * 10);

      if (error) {
        console.error("Error fetching image URLs:", error);
      } else {
        const image_urls = url_responses.map((response) => response.signedUrl);
        setInventoryImages(image_urls);
      }
    };

    if (!user_id) {
      get_user_id();
    } else {
      fetch_food_items(user_id);
    }
  }, [user_id]);

  const addNewItem = () => {
    if (newItem.trim() === "") {
      Alert.alert("Error", "Please enter a valid item name.");
      return;
    }

    const updatedFoodItems = [...food_items, { name: newItem }];
    setFoodItems(updatedFoodItems);
    setNewItem("");

    // Optionally, you can also update the food_items in the database here
    // Example:
    // await supabase.from("inventory").update({ food_items: JSON.stringify(updatedFoodItems) }).eq("user_id", user_id);
  };

  return (
    <ImageBackground
      source={inventoryImages.length > 0 ? { uri: inventoryImages[0] } : null}
      style={styles.container}
    >
      <View style={{ flex: 0.2 }}>
        <View style={styles.imageContainer}>
          {inventoryImages.map((image_url, index) => (
            <TouchableOpacity
              key={index}
              onPress={() => {
                setSelectedImage(image_url);
                setModalVisible(true);
              }}
            >
              <Image source={{ uri: image_url }} style={styles.image} />
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
            <Image source={{ uri: selectedImage }} style={styles.modalImage} />
          </View>
        </Modal>
      </View>

      <View style={{ flex: 0.8 }}>
        <ScrollView style={styles.overlay}>
          {/* Food Items */}
          <MultipleSelectList
          selectAll={true}
            setSelected={setSelected}
            selectedTextStyle={styles.selectedTextStyle}
            dropdownTextStyles={{ color: "white" }}
            data={food_items}
            save="value"
            maxHeight={900}
            placeholder={"Select items to add to inventory"}
            placeholderStyles={{ color: "white" }}
            arrowicon={
              <FontAwesome5 name="chevron-down" size={12} color={"white"} />
            }
            search={false}
            boxStyles={{
              marginTop: 10,
              marginBottom: 10,
              borderColor: "white",
            }}
            label="Inventory"
            labelStyles={{ color: "white", fontSize: 20, fontWeight: "bold" }}
            badgeStyles={{ backgroundColor: "green" }}
          />

          <View style={styles.inputContainer}>
            <TextInput
              style={styles.input}
              placeholder="Enter new item here"
              placeholderTextColor="black"
              value={newItem}
              onChangeText={(text) => setNewItem(text)}
            />
            <TouchableOpacity style={styles.addButton} onPress={addNewItem}>
              <Text style={styles.buttonText}>Add</Text>
            </TouchableOpacity>
          </View>
        </ScrollView>
      </View>
    </ImageBackground>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    resizeMode: "cover",
    backgroundColor: "black",
  },
  overlay: {
    height: "60%",
    backgroundColor: "rgba(0,0,0,0.8)",
    borderRadius: 10,
    padding: 10,
  },
  eachsection: {
    margin: 10,
  },
  text: {
    color: "white",
  },
  inputContainer: {
    flexDirection: "row",
    justifyContent: "center",
    alignItems: "center",
    margin: 10,
  },
  input: {
    width: "70%",
    height: 40,
    backgroundColor: "gray",
    borderRadius: 10,
    padding: 10,
    marginRight: 10,
  },
  addButton: {
    padding: 10,
    borderRadius: 10,
    backgroundColor: "green",
  },
  buttonText: {
    color: "white",
    fontWeight: "bold",
  },
  close: {
    position: "absolute",
    top: 40,
    right: 20,
    zIndex: 1,
    marginTop: 30,
  },
  centeredView: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    marginTop: 22,
  },
  modalView: {
    backgroundColor: "black",
    marginTop: 0,
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
  inputSearchStyle: {
    color: "white",
    backgroundColor: "black",
  },
  title: {
    fontSize: 25,
    color: "green",
    marginBottom: 20,
  },
  item: {
    flexDirection: "row",
    // alignItems: "center",
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
  button: {
    container: {
      width: 200,
      height: 50,
      backgroundColor: "green",
      borderRadius: 10,
      justifyContent: "center",
      alignItems: "center",
      marginTop: 20,
    },
    text: {
      color: "#fff",
      fontWeight: "bold",
    },
  },
});

export default Inventory;
