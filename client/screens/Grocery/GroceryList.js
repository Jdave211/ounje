import {
  StyleSheet,
  Text,
  View,
  TextInput,
  TouchableOpacity,
  Dimensions,
  Alert,
  ScrollView,
} from "react-native";
import React, { useEffect, useState } from "react";
import AsyncStorage from "@react-native-async-storage/async-storage";
import Checkbox from "expo-checkbox";
import { supabase } from "../../utils/supabase";
import axios from "axios";
import Icon from "react-native-vector-icons/FontAwesome"; // Import FontAwesome icons

const window = Dimensions.get("window");
const screenWidth = window.width || 360; // Default to 360 if undefined

const GroceryList = ({ route }) => {
  const groceryList = route?.params?.groceryList;

  const [newItem, setNewItem] = useState("");
  const [foodItems, setFoodItems] = useState([]);
  const [checkedItems, setCheckedItems] = useState(new Set());
  const [suggestions, setSuggestions] = useState([]);
  const [totalPrice, setTotalPrice] = useState("$0.00");

  const fetchFoodItems = async (itemName) => {
    const { data, error } = await supabase
      .from("food_items_grocery")
      .select("*")
      .ilike("name", `%${itemName}%`);

    if (error) {
      console.error("Error fetching food items:", error);
      return [];
    }

    const uniqueItems = Array.from(new Set(data.map((item) => item.name)))
      .map((name) => data.find((item) => item.name === name))
      .filter((item) =>
        item.name.toLowerCase().includes(itemName.toLowerCase())
      );

    // Limit suggestions to 5 items
    return uniqueItems.slice(0, 4);
  };

  const fetchPriceForItem = async (itemName) => {
    const options = {
      method: "GET",
      url: "https://grocery-pricing-api.p.rapidapi.com/searchGrocery",
      params: {
        keyword: itemName,
        perPage: "10",
        page: "1",
      },
      headers: {
        "x-rapidapi-key": process.env.SPOONACULAR_API_KEY2,
        "x-rapidapi-host": "grocery-pricing-api.p.rapidapi.com",
      },
    };

    try {
      const response = await axios.request(options);
      console.log("Response from grocery pricing API:", response.data);
      const hits = response.data.hits;
      if (hits && hits.length > 0) {
        const firstHit = hits[0];
        const priceInfo = firstHit.priceInfo;

        // Extract the price from various possible fields
        let price =
          priceInfo.itemPrice ||
          priceInfo.linePrice ||
          priceInfo.wasPrice ||
          priceInfo.unitPrice ||
          "na";

        // Remove any non-price text and keep only the price value
        price = price.replace(/[^0-9.$]/g, "").trim();

        // Ensure price starts with a dollar sign
        if (!price.startsWith("$")) {
          price = `$${price}`;
        }

        return price;
      } else {
        return "$0.00";
      }
    } catch (error) {
      console.error("Error fetching price for item:", error);
      return "$0.00";
    }
  };

  // Modified addNewItem to accept an overrideName
  const addNewItem = async (overrideName) => {
    // If overrideName isn't provided, use newItem from state
    const itemName = overrideName ?? newItem;

    if (itemName.trim() === "") return;

    const existingItems = await fetchFoodItems(itemName);
    let newItemsList = [...foodItems];

    const itemExists = newItemsList.some(
      (item) => item.name.toLowerCase() === itemName.toLowerCase()
    );

    if (!itemExists) {
      let newItemData = { id: Date.now(), name: itemName, quantity: "1" };

      const price = await fetchPriceForItem(itemName);
      newItemData.price = price;

      if (existingItems.length > 0) {
        const selectedItem = existingItems.find(
          (item) => item.name.toLowerCase() === itemName.toLowerCase()
        );
        if (selectedItem) {
          newItemData.id = selectedItem.id;
        }
      } else {
        // Exclude the price when inserting into DB
        const { id, name } = newItemData;
        const { error } = await supabase
          .from("food_items_grocery")
          .insert([{ id, name }]);

        if (error) {
          console.error("Error inserting new item:", error);
        }
      }

      newItemsList.unshift(newItemData);
      setFoodItems(newItemsList);
      await AsyncStorage.setItem("groceryItems", JSON.stringify(newItemsList));
      setNewItem("");  // Clear the input
      setSuggestions([]);
      calculateTotalPrice(newItemsList);

    } else {
      Alert.alert(
        "Duplicate Item",
        `The item "${itemName}" is already in the Grocery List.`,
        [{ text: "OK", onPress: () => setNewItem("") }]
      );
    }
  };

  const handleInputChange = async (text) => {
    setNewItem(text);
    if (text.trim() !== "") {
      const matchingItems = await fetchFoodItems(text);
      setSuggestions(matchingItems);
    } else {
      setSuggestions([]);
    }
  };

  // This function will be triggered when user taps a suggestion
  const handleSuggestionPress = async (suggestionName) => {
    // Immediately add suggestion to the list
    await addNewItem(suggestionName);
  };

  const calculateTotalPrice = (items) => {
    const total = items.reduce((sum, item) => {
      const price = parseFloat((item.price || "$0.00").replace(/[^0-9.]/g, ""));
      const quantity = parseInt(item.quantity, 10);
      return sum + (isNaN(price) || isNaN(quantity) ? 0 : price * quantity);
    }, 0);
    const totalFormatted = `$${total.toFixed(2)}`;
    setTotalPrice(totalFormatted);
  };

  const handleCheckItem = (itemId) => {
    setCheckedItems((prevChecked) => {
      const newChecked = new Set(prevChecked);
      if (newChecked.has(itemId)) {
        newChecked.delete(itemId);
      } else {
        newChecked.add(itemId);
      }
      return newChecked;
    });
  };

  const handleDeleteSelected = () => {
    const remainingItems = foodItems.filter(
      (item) => !checkedItems.has(item.id)
    );
    setFoodItems(remainingItems);
    setCheckedItems(new Set());
    AsyncStorage.setItem("groceryItems", JSON.stringify(remainingItems));
    calculateTotalPrice(remainingItems);
  };

  const handleDelete = () => {
    if (checkedItems.size > 0) {
      // Delete selected items
      handleDeleteSelected();
    } else {
      Alert.alert(
        "Delete All Items",
        "Are you sure you want to delete all items?",
        [
          { text: "Cancel", style: "cancel" },
          { text: "OK", onPress: handleClearAll },
        ],
        { cancelable: false }
      );
    }
  };

  const handleClearAll = () => {
    setFoodItems([]);
    setCheckedItems(new Set());
    AsyncStorage.removeItem("groceryItems");
    setTotalPrice("$0.00");
  };

  const handleQuantityChange = (itemId, value) => {
    setFoodItems((prevItems) => {
      const updatedItems = prevItems.map((item) => {
        if (item.id === itemId) {
          return { ...item, quantity: value };
        }
        return item;
      });
      AsyncStorage.setItem("groceryItems", JSON.stringify(updatedItems));
      calculateTotalPrice(updatedItems);
      return updatedItems;
    });
  };

  useEffect(() => {
    const loadItems = async () => {
      try {
        const storedItems = await AsyncStorage.getItem("groceryItems");
        if (storedItems) {
          const items = JSON.parse(storedItems).map((item) => ({
            ...item,
            quantity: item.quantity || "1", 
            price: item.price || "$0.00",
          }));
          setFoodItems(items);
          calculateTotalPrice(items);
        }
      } catch (error) {
        console.error("Failed to load grocery items:", error);
      }
    };

    loadItems();
  }, []);

  return (
    <View style={styles.container}>
      {/* Floating Search Bar */}
      <View style={[styles.card, styles.cardShadow]}>
        <Text style={styles.cardTitle}>Add New Item</Text>
        <View style={styles.searchContainer}>
          <View style={styles.inputContainer}>
            <TextInput
              style={styles.input}
              placeholder="Enter item"
              placeholderTextColor="gray"
              autoCapitalize="none"
              maxLength={50}
              value={newItem}
              onChangeText={handleInputChange}
            />
            <TouchableOpacity style={styles.addButton} onPress={() => addNewItem()}>
              <Text style={styles.buttonText}>+</Text>
            </TouchableOpacity>
          </View>
          {suggestions?.length > 0 && (
            <View style={styles.suggestionsContainer}>
              {suggestions.map((suggestion) => (
                <TouchableOpacity
                  key={suggestion.id}
                  style={styles.suggestion}
                  onPress={() => handleSuggestionPress(suggestion.name)}
                >
                  <Text style={styles.suggestionText}>{suggestion.name}</Text>
                </TouchableOpacity>
              ))}
            </View>
          )}
        </View>
      </View>

      {/* Action Buttons */}
      <View style={styles.actionsContainer}>
        <TouchableOpacity style={styles.actionButton} onPress={handleDelete}>
          <Icon name="trash" size={20} color="#fff" />
        </TouchableOpacity>
      </View>

      {/* Grocery List */}
      <View style={[styles.card, styles.cardShadow]}>
        <View style={styles.totalContainer}>
          <Text style={styles.totalPrice}>Total: {totalPrice}</Text>
        </View>
      </View>

      <ScrollView style={styles.scrollView}>
        <View style={styles.listContainer}>
          {foodItems?.length === 0 ? (
            <View style={styles.emptyContainer}>
              <Text style={styles.warning}>
                Your grocery list is empty. Add items to start.
              </Text>
            </View>
          ) : (
            <>
              {foodItems.map((item) => (
                <View key={item.id} style={styles.itemContainer}>
                  <Checkbox
                    style={styles.checkbox}
                    value={checkedItems.has(item.id)}
                    onValueChange={() => handleCheckItem(item.id)}
                  />
                  <View style={styles.itemDetails}>
                    <Text
                      style={[
                        styles.itemText,
                        checkedItems.has(item.id) && styles.checkedText,
                      ]}
                    >
                      {item.name}
                    </Text>
                    <View style={styles.quantityPriceContainer}>
                      <TextInput
                        style={styles.quantityInput}
                        keyboardType="numeric"
                        placeholder="Qty"
                        placeholderTextColor="#888"
                        value={item.quantity.toString()}
                        onChangeText={(value) =>
                          handleQuantityChange(item.id, value)
                        }
                      />
                      <Text style={styles.totalPriceText}>
                        {(() => {
                          const price = parseFloat(
                            (item.price || "$0.00").replace(/[^0-9.]/g, "")
                          );
                          const quantity = parseInt(item.quantity, 10);
                          const total =
                            isNaN(price) || isNaN(quantity)
                              ? "$0.00"
                              : `$${(price * quantity).toFixed(2)}`;
                          return total;
                        })()}
                      </Text>
                    </View>
                  </View>
                </View>
              ))}
            </>
          )}
        </View>
      </ScrollView>
    </View>
  );
};

export default GroceryList;

const fontSize = screenWidth ? screenWidth * 0.045 : 16;

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#1f1f1f",
    borderRadius: 12, // Curved edges
  },
  // Subtle shadow for cards (especially on Android)
  cardShadow: {
    // iOS shadow
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.2,
    shadowRadius: 2,
    // Android elevation
    elevation: 2,
  },

  scrollView: {
    flex: 1,
    paddingHorizontal: 16,
  },
  searchContainer: {
    position: "relative",
  },
  inputContainer: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 0, // Adjusted margin
  },
  input: {
    flex: 1,
    height: 40,
    borderColor: "#555",
    borderWidth: 1,
    padding: 8,
    borderRadius: 12, // Curved edges
    color: "#fff",
    backgroundColor: "#2a2a2a",
  },
  addButton: {
    marginLeft: 8,
    backgroundColor: "#3b3b3b",
    borderRadius: 12, // Curved edges
    padding: 8,
    justifyContent: "center",
    alignItems: "center",
  },
  buttonText: {
    color: "white",
    fontWeight: "bold",
    fontSize: 18,
  },
  card: {
    backgroundColor: "transparent",
    paddingHorizontal: 16,
    paddingVertical: 8,
  },
  cardTitle: {
    color: "#fff",
    fontSize: 20,
    fontWeight: "bold",
    marginBottom: 10,
  },
  totalPrice: {
    color: "#fff",
    fontSize: 20,
    fontWeight: "bold",
  },
  totalContainer: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
  },
  suggestionsContainer: {
    backgroundColor: "#3a3a3a", // Slightly lighter than #2a2a2a
    borderRadius: 12, 
    padding: 8,
    marginTop: 5, // Spacing between input and suggestions
  },
  suggestion: {
    paddingVertical: 8,
    borderBottomColor: "#555",
    borderBottomWidth: 0.5,
  },
  suggestionText: {
    color: "#ddd",
    fontSize: 16,
  },
  listContainer: {
    flexDirection: "column",
    alignItems: "flex-start",
    paddingBottom: 20,
  },
  emptyContainer: {
    alignItems: "center",
    justifyContent: "center",
    padding: 20,
  },
  warning: {
    color: "#aaa",
    textAlign: "center",
    fontSize: 16,
  },
  itemContainer: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 8,
    width: "100%",
    borderBottomColor: "#333",
    borderBottomWidth: 1,
    paddingVertical: 8,
  },
  checkbox: {
    marginRight: 12,
  },
  itemDetails: {
    flexDirection: "row",
    justifyContent: "space-between",
    flex: 1,
    alignItems: "center",
  },
  itemText: {
    fontSize: 18,
    color: "#fff",
    flex: 1,
  },
  checkedText: {
    textDecorationLine: "line-through",
    color: "#888",
  },
  quantityPriceContainer: {
    flexDirection: "row",
    alignItems: "center",
  },
  quantityInput: {
    width: 50,
    height: 30,
    borderColor: "#555",
    borderWidth: 1,
    borderRadius: 12,
    color: "white",
    paddingHorizontal: 5,
    marginRight: 10,
    textAlign: "center",
    backgroundColor: "#2a2a2a",
  },
  totalPriceText: {
    fontSize: 16,
    color: "#fff",
    width: 70,
    textAlign: "right",
  },
  actionsContainer: {
    flexDirection: "row",
    justifyContent: "flex-end",
    paddingHorizontal: 16,
    marginBottom: 10,
  },
  actionButton: {
    backgroundColor: "#3b3b3b",
    borderRadius: 12,
    padding: 10,
    alignItems: "center",
    flexDirection: "row",
    marginTop: 15,
  },
  actionText: {
    color: "#fff",
    fontSize: 14,
  },
});