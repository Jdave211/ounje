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
  Alert,
  TextInput,
} from "react-native";
import { FontAwesome5 } from "@expo/vector-icons";
import { AntDesign } from "@expo/vector-icons";
import RecipeCard from "../components/RecipeCard";
import { MultipleSelectList } from "../components/MultipleSelectList";
import axios from "axios";
import { supabase, store_image } from "../utils/supabase";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { FOOD_ITEMS } from "../utils/constants";
import { RECIPES_PROMPT } from "@utils/prompts";
import { generate_image } from "../utils/stability";
import { entitle } from "@utils/helpers";
import { useNavigation } from "@react-navigation/native";
import CaseConvert, { objectToSnake } from "ts-case-convert";

const Inventory = () => {
  const navigation = useNavigation();

  const [selected, setSelected] = useState([]);
  const [isDropdownOpen, setIsDropdownOpen] = useState(false);
  const [modalVisible, setModalVisible] = useState(false);
  const [selectedImage, setSelectedImage] = useState(null);
  const [food_items, setFoodItems] = useState(FOOD_ITEMS);
  const [food_items_array, setFoodItemsArray] = useState([]);
  const [inventoryImages, setInventoryImages] = useState([]);
  const [user_id, setUserId] = useState(null);
  const [newItem, setNewItem] = useState("");

  useEffect(() => {
    const get_user_id = async () => {
      let retrieved_user_id = await AsyncStorage.getItem("user_id");
      setUserId(() => retrieved_user_id);
    };

    const fetch_food_items = async () => {
      let retrieved_text = await AsyncStorage.getItem("food_items");
      let retrieved_food_items = JSON.parse(retrieved_text);

      retrieved_text = await AsyncStorage.getItem("food_items_array");
      let retrieved_food_items_array = JSON.parse(retrieved_text);

      if (retrieved_food_items) {
        setFoodItems(() => retrieved_food_items);
      }

      if (retrieved_food_items_array?.length > 0) {
        setFoodItemsArray(() => retrieved_food_items_array);
      }
    };

    const fetch_inventory_images = async () => {
      let {
        data: [inventory],
      } = await supabase
        .from("inventory")
        .select("images")
        .eq("user_id", user_id);

      let image_paths = inventory.images.map((image) =>
        image.replace("inventory_images/", "")
      );

      let { data: url_responses } = await supabase.storage
        .from("inventory_images")
        .createSignedUrls(image_paths, 60 * 10);

      let image_urls = url_responses.map((response) => response.signedUrl);

      setInventoryImages(() => image_urls);
    };

    if (!user_id) {
      get_user_id();
      fetch_food_items();
    } else {
      fetch_inventory_images();
      fetch_food_items();
    }
  }, [user_id]);

  console.log({ inventoryImages });

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
    <ScrollView
      style={styles.container}
      // contentContainerStyle={{
      //   justifyContent: "space-between",
      //   alignItems: "space-evenly",
      // }}
    >
      {/* <ImageBackground
        source={inventoryImages.length > 0 ? { uri: inventoryImages[0] } : null}
        style={styles.container}
      > */}
      <Text style={{ color: "white" }}> Inventory</Text>
      {/* Inventory Images */}
      <View style={{ flex: 0.2 }}>
        <View style={{ ...styles.imageContainer, backgroundColor: "#" }}>
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
          style
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

      <ScrollView style={styles.overlay}>
        {/* Food Items */}
        {Object.entries(food_items).map(([section, categories]) => {
          let data = Object.entries(categories).flatMap(
            ([category, items], i) =>
              items.map((item, i) => ({
                key: item.name,
                value: item.name,
              }))
          );

          return (
            <MultipleSelectList
              key={section}
              setSelected={setSelected}
              selectedTextStyle={styles.selectedTextStyle}
              dropdownTextStyles={{ color: "white" }}
              // defaultOptions={[data[0].value]}
              data={data}
              save="value"
              maxHeight={900}
              placeholder={"placeholder"}
              placeholderStyles={{ color: "white" }}
              arrowicon={
                <FontAwesome5 name="chevron-down" size={12} color={"white"} />
              }
              searchicon={
                <FontAwesome5 name="search" size={12} color={"white"} />
              }
              searchPlaceholder="Search..."
              search={false}
              boxStyles={{
                marginTop: 10,
                marginBottom: 10,
                borderColor: "white",
              }}
              label={entitle(section)}
              labelStyles={{
                color: "white",
                fontSize: 14,
                fontWeight: "bold",
              }}
              badgeStyles={{ backgroundColor: "green" }}
            />
          );
        })}

        {/* Add Food Items Button */}

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
        {/* Generate Recipe Button */}
        <View style={styles.centerItems}>
          <TouchableOpacity
            style={styles.button.container}
            // onPress={}
            disabled={selected.length === 0}
          >
            <Text style={styles.button.text}>Update Inventory</Text>
          </TouchableOpacity>
        </View>
      </ScrollView>
      {/* </ImageBackground> */}
    </ScrollView>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
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
    width: "100%", // Adjust as needed
    justifyContent: "space-evenly",
    alignItems: "center",
    flexDirection: "row",
    flexWrap: "wrap",
  },
  image: {
    margin: 10,
    borderRadius: 10,
    width: 100,
    height: 100, // Adjust as needed
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
