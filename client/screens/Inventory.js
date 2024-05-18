import React, { useState, useEffect } from "react";
import { View, Text, StyleSheet, ScrollView } from "react-native";
import { CheckBox } from "react-native-elements";
import axios from "axios";
import { supabase } from "../utils/supabase";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { FOOD_ITEMS } from "../utils/constants";

const Inventory = () => {
  const [selectedItems, setSelectedItems] = useState({});
  const [emojiData, setEmojiData] = useState(null);
  const [food_items, setFoodItems] = useState(FOOD_ITEMS);

  useEffect(() => {
    const fetch_food_items = async () => {
      let retrieved_text = await AsyncStorage.getItem("food_items");
      let retrieved_food_items = JSON.parse(retrieved_text);

      setFoodItems(() => retrieved_food_items);
    };

    fetch_food_items();
  }, []);

  console.log({ food_items });
  // const food_item_records = supabase.from("food_items")
  //   .select("*")

  const handleCheck = (section, item) => {
    setSelectedItems((prevState) => ({
      ...prevState,
      [section]: {
        ...prevState[section],
        [item.name]: !prevState[section]?.[item.name],
      },
    }));
  };

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

  return (
    <ScrollView style={styles.container}>
      <View style={styles.eachsection}>
        {Object.entries(food_items).map(([section, items]) => (
          <View key={section}>
            <Text style={[styles.text, styles.title]}>{section}</Text>
            {Object.entries(items).map(([shelf, shelfItems]) => (
              <View key={shelf}>
                <Text style={styles.text}>{shelf}</Text>
                {shelfItems.map((item) => (
                  <View key={item.name} style={styles.item}>
                    <CheckBox
                      value={selectedItems[section]?.[item.name] || false}
                      onValueChange={() => handleCheck(section, item)}
                    />
                    <Text style={styles.text}>{item.name}</Text>
                  </View>
                ))}
              </View>
            ))}
          </View>
        ))}
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
