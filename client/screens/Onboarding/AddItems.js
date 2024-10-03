//AddItems.js
import React, { useState } from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
} from "react-native";
import { POPULAR_ITEMS } from "../../utils/constants"; // Importing from constants.js

const AddItems = () => {
  const [inventory, setInventory] = useState([]);

  // Function to handle item selection
  const handleSelectItem = (item) => {
    if (!inventory.includes(item)) {
      setInventory([...inventory, item]);
    }
  };

  // Render each food item in a bubble
  const renderFoodItem = ({ item }) => {
    console.log("======================================== item", item);
    return (
      <TouchableOpacity
        style={[
          styles.foodItem,
          inventory.includes(item) ? styles.selectedItem : null,
        ]}
        onPress={() => {
          handleSelectItem(item);
        }}
        activeOpacity={0.7}
      >
        <Text style={styles.foodItemText}>{item}</Text>
      </TouchableOpacity>
    );
  };

  console.log(
    "================================================ POPULAR_ITEMS : ",
    POPULAR_ITEMS
  );

  return (
    <View style={styles.container}>
        {POPULAR_ITEMS && POPULAR_ITEMS.length > 0 ? (
          <FlatList
            style={{ zIndex: 1 }}
            data={POPULAR_ITEMS}
            renderItem={renderFoodItem}
            keyExtractor={(item, index) => index.toString()}
            numColumns={3}
            columnWrapperStyle={styles.row}
          />
        ) : (
          <Text>No items available</Text>
        )}
    
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 20,
    backgroundColor: "#f8f8f7",
  },
  title: {
    fontSize: 22,
    fontWeight: "bold",
    marginBottom: 20,
    textAlign: "center",
  },
  foodItem: {
    backgroundColor: "#fff",
    paddingVertical: 15,
    paddingHorizontal: 10,
    borderRadius: 25,
    margin: 5,
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    elevation: 3,
    minHeight: 60,
    zIndex: 1,
  },
  selectedItem: {
    backgroundColor: "#add8e6", // Light blue background for selected items
  },
  foodItemText: {
    fontSize: 14,
    color: "#000",
  },
  row: {
    justifyContent: "space-between",
  },
  inventory: {
    marginTop: 20,
    padding: 10,
    backgroundColor: "#fff",
    borderRadius: 10,
    elevation: 2,
  },
  inventoryTitle: {
    fontSize: 18,
    fontWeight: "bold",
    marginBottom: 10,
  },
  inventoryItem: {
    fontSize: 16,
    color: "#333",
  },
  emptyInventory: {
    fontSize: 16,
    fontStyle: "italic",
    color: "#999",
  },
});

export default AddItems;
