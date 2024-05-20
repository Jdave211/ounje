import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  Image,
  TouchableOpacity,
  Modal,
} from "react-native";
import { FontAwesome5 } from "@expo/vector-icons";
import { AntDesign } from "@expo/vector-icons";
import RecipeCard from "../components/RecipeCard";
import { MultipleSelectList } from "../components/MultipleSelectList";
import axios from "axios";
import { supabase, store_image } from "../utils/supabase";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { FOOD_ITEMS } from "../utils/constants";
import { RECIPES_PROMPT } from "../utils/prompts";
import { generate_image } from "../utils/stability";

const Inventory = () => {
  const [selected, setSelected] = useState([]);
  const [isDropdownOpen, setIsDropdownOpen] = useState(false);
  const [modalVisible, setModalVisible] = useState(false);
  const [selectedImage, setSelectedImage] = useState(null);
  const [food_items, setFoodItems] = useState(FOOD_ITEMS);
  const [food_items_array, setFoodItemsArray] = useState([]);
  const [inventoryImages, setInventoryImages] = useState([]);
  const [user_id, setUserId] = useState(null);

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
        image.replace("inventory_images/", ""),
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

  const generate_recipes = async () => {
    let async_run_response = supabase
      .from("runs")
      .insert([{ user_id, images: image_paths }])
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
    const selected_food_items = food_items_array.filter((item) =>
      selected_set.has(item.name),
    );
    const food_item_records = selected_food_items.map((record) => ({
      run_id: current_run.id,
      ...record,
    }));

    console.log("food_item_records: ", food_item_records);

    await supabase.from("food_items").upsert(food_item_records).throwOnError();

    console.log("starting recipes");

    let recipe_system_prompt = { role: "system", content: RECIPES_PROMPT };
    let recipe_user_prompt = {
      role: "user",
      content: selected_food_items.join(", "),
    };
    let recipe_response = await openai.chat.completions.create({
      model: "gpt-4o",
      messages: [recipe_system_prompt, recipe_user_prompt],
    });

    console.log({ recipe_response });

    let { object: recipe_options } = extract_json(recipe_response);

    console.log("recipe_options: ", recipe_options);

    await AsyncStorage.setItem(
      "recipe_options",
      JSON.stringify(recipe_options),
    );

    // navigate to recipes screen to select options to keep
    // once selected, save the selected options to the database
  };

  const store_selected_recipes = async (selected_recipes) => {
    const recipe_image_bucket = "recipe_images";

    const recipe_image_gen_data = selected_recipes.map((recipe) => ({
      prompt:
        "a zoomed out image showing the full dish of " + recipe.image_prompt,
      storage_path: `${current_run.id}/${recipe.name}.jpeg`,
    }));

    // generate and store images for each recipe
    // shoot and forget approach
    // no need to wait for the images to be generated or stored
    // we just let them run while we continue with the rest of the process
    // the urls to the image can be calculated from the storage path
    // so we can pass that into the app and it can fetch the images as needed
    await Promise.allSettled(
      selected_recipes.map(async (recipe) => {
        let recipe_image = await generate_image(
          "a zoomed out image showing the full dish of " + recipe.image_prompt,
        );

        let storage_path = `${current_run.id}/${recipe.name}.jpeg`;
        let image_storage_response = await store_image(
          recipe_image_bucket,
          storage_path,
          recipe_image,
        );

        return image_storage_response;
      }),
    );

    const recipe_records = selected_recipes.map((recipe) => {
      delete recipe.image_prompt;
      let storage_path = `${current_run.id}/${recipe.name}.jpeg`;

      let {
        data: { publicUrl: image_url },
      } = supabase.storage.from(recipe_image_bucket).getPublicUrl(storage_path);

      recipe["image_url"] = image_url;

      return recipe;
    });

    console.log("recipe_records: ", recipe_records);

    return await supabase
      .from("recipes")
      .upsert(recipe_records, { onConflict: ["name"] })
      .throwOnError();
  };

  const capitalize = (s) => s.charAt(0).toUpperCase() + s.slice(1);
  const entitle = (name) => capitalize(name.split("_").join(" "));

  return (
    <ScrollView
      style={styles.container}
      // contentContainerStyle={{
      //   justifyContent: "space-between",
      //   alignItems: "space-evenly",
      // }}
    >
      {/* Inventory Images */}
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

      {/* Inventory Images */}
      {Object.entries(food_items).map(([section, categories]) => {
        let data = Object.entries(categories).flatMap(([category, items], i) =>
          items.map((item, i) => ({
            key: item.name,
            value: item.name,
          })),
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
              marginTop: 25,
              marginBottom: 25,
              borderColor: "white",
            }}
            label={entitle(section)}
            labelStyles={{ color: "green", fontSize: 20, fontWeight: "bold" }}
            badgeStyles={{ backgroundColor: "green" }}
          />
        );
      })}

      {/* Generate Recipe Button */}
      <View style={styles.centerItems}>
        <TouchableOpacity
          style={styles.button.container}
          onPress={generate_recipes}
          disabled={selected.length === 0}
        >
          <Text style={styles.button.text}>Generate</Text>
        </TouchableOpacity>
      </View>
    </ScrollView>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "black",
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
