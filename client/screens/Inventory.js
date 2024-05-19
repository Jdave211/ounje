import React, { useState, useEffect } from "react";
import { View, Text, StyleSheet, ScrollView } from "react-native";
import { CheckBox } from "react-native-elements";
import { MultipleSelectList } from "react-native-dropdown-select-list";
import { FontAwesome5 } from "@expo/vector-icons";
import RecipeCard from "../components/RecipeCard";
import axios from "axios";
import { supabase } from "../utils/supabase";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { FOOD_ITEMS } from "../utils/constants";

const Inventory = () => {
  const [selectedItems, setSelectedItems] = useState({});
  const [selected, setSelected] = useState([]);
  const [isDropdownOpen, setIsDropdownOpen] = useState(false);
  const [emojiData, setEmojiData] = useState(null);
  const [food_items, setFoodItems] = useState(FOOD_ITEMS);

  const handleCheck = (section, item) => {
    setSelectedItems((prevState) => ({
      ...prevState,
      [section]: {
        ...prevState[section],
        [item.name]: !prevState[section]?.[item.name],
      },
    }));
  };

  useEffect(() => {
    const fetch_food_items = async () => {
      let retrieved_text = await AsyncStorage.getItem("food_items");
      let retrieved_food_items = JSON.parse(retrieved_text);

      setFoodItems(() => retrieved_food_items);
    };
    fetch_food_items();
  }, []);

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
            arrowicon={
              <FontAwesome5 name="chevron-down" size={12} color={"black"} />
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
    backgroundColor: "black",
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
});

export default Inventory;
