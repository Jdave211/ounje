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
  const generate_recipes = async () => {
    let async_run_response = supabase
      .from("runs")
      .insert([{ user_id, images: inventoryImages }])
      .select()
      .throwOnError();

    const [
      {
        value: { data: runs, error: runs_error },
      },
    ] = await Promise.allSettled([async_run_response]);

    if (runs_error) console.log("Error:", runs_error);
    else console.log("Added User Run:", runs);

    console.log("runs: ", runs);
    current_run = runs[runs.length - 1];

    console.log("current_run: ", current_run);

    let selected_set = new Set(selected);
    const selected_food_items = food_items_array.filter(
      (item) =>
        // selected_set.has(item.name),
        true
    );
    const food_item_records = selected_food_items.map((record) => ({
      run_id: current_run.id,
      ...record,
    }));

    console.log("food_item_records: ", food_item_records);

    await supabase.from("food_items").upsert(food_item_records).throwOnError();

    console.log("starting recipes");

    const { data: recipe_response } = await axios.get(
      "https://api.spoonacular.com/recipes/findByIngredients",
      {
        params: {
          apiKey: process.env.SPOONACULAR_API_KEY,
          ingredients: food_items_array.map(({ name }) => name).join(", "),
          number: 7,
          ranking: 1,
        },
      }
    );

    let recipe_options = recipe_response;

    console.log({ recipe_options });

    // let { object: recipe_options } = extract_json(recipe_response);

    console.log("recipe_options: ", recipe_options);

    await AsyncStorage.setItem(
      "recipe_options",
      JSON.stringify(recipe_options)
    );

    // navigate to recipes screen to select options to keep
    // once selected, save the selected options to the database
    navigation.navigate("RecipeOptions");
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
