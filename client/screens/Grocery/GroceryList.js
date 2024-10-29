import {
  StyleSheet,
  Text,
  View,
  TextInput,
  TouchableOpacity,
  Dimensions,
  Alert,
  Image,
} from "react-native";
import React, { useEffect, useState } from "react";
import AsyncStorage from "@react-native-async-storage/async-storage";
import IngredientCard from "../../components/IngredientCard";
import Empty from "../../components/Empty";
import { supabase } from "../../utils/supabase";
import Checkbox from "expo-checkbox";

const screenWidth = Dimensions.get("window").width;

const GroceryList = () => {
  const [newItem, setNewItem] = useState("");
  const [foodItems, setFoodItems] = useState([]);
  const [checkedItems, setCheckedItems] = useState(new Set());
  const [suggestions, setSuggestions] = useState([]);

  // Function to fetch unique food items based on item name
const fetchFoodItems = async (itemName) => {
  const { data, error } = await supabase
    .from("food_items_grocery")
    .select("*")
    .ilike("name", `%${itemName}%`);

  if (error) {
    console.error("Error fetching food items:", error);
    return [];
  }

  // Create a Set to filter out duplicate items based on their name
  const uniqueItems = Array.from(new Set(data.map(item => item.name)))
    .map(name => data.find(item => item.name === name));

  return uniqueItems;
};

const handleInputChange = async (text) => {
  setNewItem(text);
  if (text.trim() !== "") {
    const matchingItems = await fetchFoodItems(text);
    setSuggestions(matchingItems); // Show suggestions based on input
  } else {
    setSuggestions([]);
  }
};

  const addNewItem = async () => {
    if (newItem.trim() === "") return;

    const existingItems = await fetchFoodItems(newItem);
    let newItemsList = [...foodItems];

    const itemExists = newItemsList.some(
      (item) => item.name.toLowerCase() === newItem.toLowerCase()
    );

    if (!itemExists) {
      if (existingItems.length > 0) {
        existingItems.forEach((item) => {
          if (
            !newItemsList.some(
              (existingItem) =>
                existingItem.name.toLowerCase() === item.name.toLowerCase()
            )
          ) {
            newItemsList.push(item);
          }
        });
      } else {
        const newItemData = { id: Date.now(), name: newItem, image: null };
        const { error } = await supabase
          .from("food_items_grocery")
          .insert([newItemData]);

        if (!error) {
          newItemsList.push(newItemData);
        }
      }
    } else {
      Alert.alert(
        "Duplicate Item",
        `The item "${newItem}" is already in the Grocery List.`,
        [{ text: "OK", onPress: () => setNewItem("") }]
      );
      return;
    }

    setFoodItems(newItemsList);
    await AsyncStorage.setItem("groceryItems", JSON.stringify(newItemsList)); // Persist all items
    setNewItem("");
    setSuggestions([]); // Clear suggestions after adding
  };

  const handleCheckItem = async (itemId) => {
    if (checkedItems.has(itemId)) {
      setCheckedItems((prevChecked) => {
        const newChecked = new Set(prevChecked);
        newChecked.delete(itemId);
        return newChecked;
      });
    } else {
      setFoodItems((prevItems) => {
        const updatedItems = prevItems.filter((item) => item.id !== itemId);
        AsyncStorage.setItem("groceryItems", JSON.stringify(updatedItems)); // Persist the updated list
        return updatedItems;
      });
      setCheckedItems((prevChecked) => new Set(prevChecked).add(itemId));
    }
  };
  useEffect(() => {
    const loadItems = async () => {
      try {
        const storedItems = await AsyncStorage.getItem("groceryItems");
        if (storedItems) {
          const items = JSON.parse(storedItems);
          setFoodItems(items);
        }
      } catch (error) {
        console.error("Failed to load grocery items:", error);
      }
    };

    loadItems();
  }, []); // This empty dependency array ensures this runs only on mount

  return (
    <View style={styles.container}>
      {/* <Text style={styles.header}>Grocery List</Text> */}
      <View style={styles.card}>
        <Text style={styles.cardTitle}>Add New Grocery Item</Text>
        <View style={styles.inputContainer}>
          <TextInput
            style={styles.input}
            placeholder="Enter your grocery item"
            placeholderTextColor="gray"
            autoCapitalize="none"
            maxLength={50}
            value={newItem}
            onChangeText={handleInputChange}
          />
          <TouchableOpacity style={styles.addButton} onPress={addNewItem}>
            <Text style={styles.buttonText}>Add</Text>
          </TouchableOpacity>
        </View>
        {suggestions.length > 0 && (
        <View style={{marginTop: 10}}>
          {suggestions.map((suggestion) => (
            <TouchableOpacity
              key={suggestion.id}
              style={{
                flexDirection: "row",
                alignItems: "center",
                marginBottom: 10,
              }}
              onPress={() => {
                setNewItem(suggestion.name); // Set the selected suggestion to the TextInput
                setSuggestions([]); // Clear suggestions
              }}
            >
             <View style={{flexDirection: 'row',  width: 150,gap: 20,
             paddingHorizontal: 40,
    height: 80,
    borderRadius: 10,
    backgroundColor: "rgba(0, 0, 0, 0.2)",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 4,}}>
              <Image
                source={{
                  uri: suggestion.image
                    ? `https://img.spoonacular.com/ingredients_100x100/${suggestion.image}`
                    : null,
                }}
                style={{width: 50,
                  height: 50,
                  borderRadius: 10,}} // Adjust size as needed
              />
              <Text style={{ color: "#fff"}}>
                {suggestion.name}
              </Text>
              </View> 
            </TouchableOpacity>
          ))}
        </View>
      )}
      </View>

      

      <View style={styles.card}>
              <Text style={styles.cardTitle}>Grocery Items</Text>
              <View style={styles.centeredContainer}>
        {foodItems.length === 0 ? (
          <View
            style={{
              flex: 2,
              justifyContent: "center",
              alignContent: "center",
            }}
          >
            <Empty />
            <Text style={styles.warning}>
              Your grocery list is empty. Add some items to get started.
            </Text>
          </View>
        ) : (
          <View>
            {foodItems.map((item) => {
              return (
                <View
                  key={item.id}
                  style={{
                    flexDirection: "row",
                    alignItems: "center",
                    marginBottom: 10,
                    gap: 30,
                  }}
                >
                  <Checkbox
                    value={checkedItems.has(item.id)}
                    onValueChange={() => handleCheckItem(item.id)}
                  />
                  <View style={{ width: 90, marginRight: 10 }}>
                    <IngredientCard
                      name={item.name}
                      image={
                        item.image
                          ? `https://img.spoonacular.com/ingredients_100x100/${item.image}`
                          : null
                      }
                      GroceryItem={true}
                    />
                  </View>
                </View>
              );
            })}
          </View>
        )}
      </View>
      </View>
    </View>
  );
};

export default GroceryList;

const styles = StyleSheet.create({
  container: {
    // padding: 10,
  },
  header: {
    color: "#ffff",
    fontSize: 24,
    fontWeight: "bold",
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
  warning: {
    color: "#fff",
    textAlign: "center",
  },
  card: {
    backgroundColor: "#1f1f1f",
    borderRadius: 10,
    padding: 20,
    marginBottom: 20,
  },
  cardTitle: {
    color: "#fff",
    fontSize: screenWidth * 0.045,
    fontWeight: "bold",
    marginBottom: 10,
  },
  inputContainer: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 10,
  },
});
