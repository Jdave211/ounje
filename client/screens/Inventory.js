import React, { useState, useEffect } from "react";
import { View, Text, StyleSheet, ScrollView, Image } from "react-native";
import { CheckBox } from "react-native-elements";
import { MultipleSelectList } from "react-native-dropdown-select-list";
import { FontAwesome5 } from "@expo/vector-icons";
import RecipeCard from "../components/RecipeCard";
import axios from "axios";
import { supabase } from "../utils/supabase";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { FOOD_ITEMS } from "../utils/constants";

const Inventory = () => {
  const [selected, setSelected] = useState([]);
  const [isDropdownOpen, setIsDropdownOpen] = useState(false);
  const [emojiData, setEmojiData] = useState(null);
  const [food_items, setFoodItems] = useState(FOOD_ITEMS);
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

      if (retrieved_food_items) {
        setFoodItems(() => retrieved_food_items);

      // Set selected items to all items
      const allItems = Object.entries(retrieved_food_items).flatMap(([section, items]) =>
        Object.entries(items).flatMap(([shelf, shelfItems]) =>
          shelfItems.map((item) => item.name),
        ),
      );
      setSelected(allItems);
    };
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

  // useEffect(() => {
  //   const options = {
  //     method: "GET",
  //     url: "https://emoji-ai.p.rapidapi.com/getEmoji",
  //     headers: {
  //       "X-RapidAPI-Key": "",
  //       "X-RapidAPI-Host": "emoji-ai.p.rapidapi.com",
  //     },
  //   };

  //   Object.entries(food_items).forEach(([section, items]) => {
  //     Object.entries(items).forEach(([shelf, shelfItems]) => {
  //       shelfItems.forEach((item) => {
  //         axios
  //           .request({
  //             ...options,
  //             params: { query: item.name },
  //           })
  //           .then((response) => {
  //             setEmojiData((prevState) => ({
  //               ...prevState,
  //               [item.name]: response.data,
  //             }));
  //           })
  //           .catch((error) => {
  //             console.error(error);
  //           });
  //       });
  //     });
  //   });
  // }, [food_items]);

  const mapFoodData = (sectionFilter) => {
    return Object.entries(food_items).flatMap(([section, items]) =>
      sectionFilter(section)
        ? Object.entries(items).flatMap(([shelf, shelfItems]) =>
            shelfItems.map((item) => ({
              key: `${section}-${shelf}-${item.name}`,
              value: `${item.name}`,
            })),
          )
        : [],
    );
  };

  const capitalize = (s) => s.charAt(0).toUpperCase() + s.slice(1);
  const entitle = (name) => capitalize(name.split("_").join(" "));

  return (
    <ScrollView style={styles.container}>
      <View style={styles.imageContainer}>
        {inventoryImages.map((image_url, index) => (
          <View key={index}>
            <Image source={{ uri: image_url }} style={styles.image} />
          </View>
        ))}
      </View>
      {Object.entries(food_items).map(([section, categories]) => {
        let data = Object.entries(categories).flatMap(([category, items], i) =>
          items.map((item, i) => ({
            key: `${section}-${category}-${item.name}`,
            value: item.name,
          })),
        );

        return (
          <MultipleSelectList
            key={section}
            setSelected={setSelected}
            selectedTextStyle={styles.selectedTextStyle}
            dropdownTextStyles={{ color: "white" }}
            data={data}
            save="value"
            maxHeight={900}
            placeholder={entitle(section)}
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
    </ScrollView>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "white",
  },
  eachsection: {
    margin: 10,
  },
  text: {
    color: "white",
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
    alignItems: "center",
  },
  imageContainer: {
    width: 150, // Adjust as needed
    marginLeft: 110, // Adjust as needed
    justifyContent: "center",
  },
  image: {
    width: "100%",
    height: 130, // Adjust as needed
  },
});

export default Inventory;
