import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  TextInput,
  Button,
  StyleSheet,
  TouchableOpacity,
  ScrollView,
} from "react-native";
import { FontAwesome5 } from "@expo/vector-icons";
import Toast from "react-native-toast-message";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { SelectList } from "react-native-dropdown-select-list";
import MultipleSelectList from "@components/MultipleSelectList";
import { FOOD_ITEMS } from "@utils/constants";
import { entitle, group_nested_objects } from "@utils/helpers";
import { useNavigation } from "@react-navigation/native";

const CheckIngredients = () => {
  const navigation = useNavigation();
  const [selected, setSelected] = useState([]);
  const [data, setData] = useState([
    { key: "1", value: "Rice" },
    { key: "2", value: "Eggs" },
    { key: "3", value: "Ostrich head" },
  ]);
  const [removed_items, set_removed_items] = useState([]);
  const [inputValue, setInputValue] = useState("");

  const [user_id, setUserId] = useState(null);
  const [food_items, setFoodItems] = useState(FOOD_ITEMS);
  const [food_items_array, setFoodItemsArray] = useState([]);

  const [selectedInventoryItem, setSelectedInventoryItem] = useState(null);
  const [selectedItemCategory, setSelectedItemCategory] = useState(null);

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

    if (!user_id) {
      get_user_id();
    }
    fetch_food_items();
  }, [user_id]);

  const handleAddIngredient = () => {
    if (inputValue.length === 0 || !inputValue.trim()) {
      Toast.show({
        type: "error",
        text1: "Empty Items List",
        text2: "Please enter an ingredient to add.",
      });
      return;
    }

    const newIngredient = {
      key: (data.length + 1).toString(),
      value: inputValue.trim(),
    };

    setData([...data, newIngredient]);
    setInputValue("");

    Toast.show({
      type: "success",
      text1: "Ingredient Added",
      text2: `${inputValue.trim()} has been added to the list.`,
    });
  };

  const handleRemoveIngredients = () => {
    if (removed_items.length === 0) {
      Toast.show({
        type: "error",
        text1: "No Ingredients Selected",
        text2: "Please select ingredients to remove.",
      });
      return;
    }

    let removed_items_set = new Set(removed_items);

    const filtered_food_items = food_items_array.filter(
      (item) => !removed_items_set.has(item.name),
    );

    setFoodItemsArray(filtered_food_items);

    let food_items_object = group_nested_objects(filtered_food_items, [
      "inventory",
      "category",
    ]);

    setFoodItems(food_items_object);

    Toast.show({
      type: "info",
      text1: "Ingredients Removed",
      text2: `Ingredients have been removed from the list.`,
    });
  };

  const handleGenerateRecipes = async () => {
    if (food_items_array.length === 0) {
      Toast.show({
        type: "error",
        text1: "Empty Food Items List",
        text2: "Please add ingredients to generate a recipe.",
      });

      return;
    }

    await AsyncStorage.setItem("food_items", JSON.stringify(food_items));
    await AsyncStorage.setItem(
      "food_items_array",
      JSON.stringify(food_items_array),
    );

    // we can also just generate recipes here and
    // navigate to the recipe options page
    navigation.navigate("Inventory");
  };

  const AddItemInventorySelection = () => {
    const data = Object.keys(food_items).map((section, i) => ({
      key: i.toString(),
      value: section,
    }));

    return (
      <SelectList
        setSelected={(value) => {
          const entry = data.find((kv) => kv.value === value);
          if (selectedInventoryItem?.value !== entry?.value) {
            setSelectedInventoryItem(entry);
            setSelectedItemCategory(null); // Reset category when inventory changes
          }
        }}
        data={data}
        save="value"
        search={false}
        labelStyles={styles.labelStyles}
        dropdownTextStyles={styles.dropdownTextStyles}
        badgeStyles={styles.badgeStyles}
        placeholder="Select Inventory"
        placeholderStyles={styles.placeholderStyles}
      />
    );
  };

  const AddItemCategorySelection = () => {
    if (!selectedInventoryItem) return null;

    const data = Object.keys(food_items[selectedInventoryItem.value]).map(
      (section, i) => ({
        key: i.toString(),
        value: section,
      })
    );

    return (
      <SelectList
        setSelected={(value) => {
          const entry = data.find((kv) => kv.value === value);
          if (selectedItemCategory?.value !== entry?.value) {
            setSelectedItemCategory(entry);
          }
        }}
        data={data}
        save="value"
        search={false}
        labelStyles={styles.labelStyles}
        dropdownTextStyles={styles.dropdownTextStyles}
        badgeStyles={styles.badgeStyles}
        placeholder="Select Category"
        placeholderStyles={styles.placeholderStyles}
      />
    );
  };

  return (
    <ScrollView style={styles.scrollContainer}>
      <View style={styles.container}>
        <Text style={styles.title}>Check Ingredients</Text>
        <Text style={styles.warningText}>
          The model we are currently using is prone to{" "}
          <Text style={styles.hallucinationText}>hallucination.</Text>{" "}
          Please double-check your food items.
        </Text>

<<<<<<< Updated upstream
          <View style={styles.dropdownContainer}>
            <Text style={{ color: "white" }}> Select Items to Remove </Text>
            {Object.entries(food_items).map(([section, categories]) => {
              let data = Object.entries(categories).flatMap(
                ([_category, items], _i) =>
                  items.map((item, _i) => ({
                    key: item.name,
                    value: item.name,
                  })),
              );
=======
        <View style={styles.dropdownContainer}>
          <Text style={styles.sectionTitle}>Select Items to Remove</Text>
          {Object.entries(food_items).map(([section, categories]) => {
            let data = Object.entries(categories).flatMap(
              ([_category, items], _i) =>
                items.map((item, _i) => ({
                  key: item.name,
                  value: item.name,
                }))
            );
>>>>>>> Stashed changes

            return (
              <MultipleSelectList
                key={section}
                setSelected={set_removed_items}
                selectedTextStyle={styles.selectedTextStyle}
                data={data}
                save="value"
                maxHeight={900}
                placeholder="Select items to remove"
                placeholderStyles={styles.placeholderStyles}
                arrowicon={
                  <FontAwesome5 name="chevron-down" size={12} color="white" />
                }
                searchicon={
                  <FontAwesome5 name="search" size={12} color="white" />
                }
                searchPlaceholder="Search..."
                search={false}
                boxStyles={styles.multipleSelectBoxStyles}
                label={entitle(section) + " Items"}
                labelStyles={styles.labelStyles}
                dropdownTextStyles={styles.dropdownTextStyles}
                badgeStyles={styles.badgeStyles}
              />
            );
          })}
          <View style={styles.addButtonContainer}>
            <Button
              title="Remove Items"
              color="red"
              onPress={handleRemoveIngredients}
            />
          </View>
        </View>
<<<<<<< Updated upstream
        <View style={styles.generateButtonWrapper}>
          <View style={styles.generateButtonContainer}>
            <TouchableOpacity
              style={styles.generateButton}
              disabled={data.length === 0}
              onPress={handleGenerateRecipes}
            >
              <Text style={styles.generateButtonText}>Generate Recipes</Text>
            </TouchableOpacity>
=======

        <View style={styles.dropdownContainer2}>
          <Text style={styles.sectionTitle}>Add Item to Inventory</Text>

          <View style={styles.row}>
            <Text style={styles.labelText}>Inventory: </Text>
            <AddItemInventorySelection />
>>>>>>> Stashed changes
          </View>

          <View style={styles.row}>
            <Text style={styles.labelText}>Category: </Text>
            <AddItemCategorySelection />
          </View>

          <View style={styles.row}>
            <Text style={styles.labelText}>Item: </Text>
            <TextInput
              style={styles.input}
              placeholder="Add Missing Ingredients"
              value={inputValue}
              onChangeText={setInputValue}
              placeholderTextColor="gray"
              autoCapitalize="none"
            />
          </View>

          <View style={styles.addButtonContainer}>
            <Button title="Add Item" color="green" onPress={handleAddIngredient} />
          </View>
        </View>

        <View style={styles.generateButtonWrapper}>
          <TouchableOpacity
            style={styles.generateButton}
            disabled={data.length === 0}
            onPress={handleGenerateRecipes}
          >
            <Text style={styles.generateButtonText}>Save Food Items</Text>
          </TouchableOpacity>
        </View>
      </View>
    </ScrollView>
  );
};

const styles = StyleSheet.create({
  scrollContainer: {
    flex: 1,
    backgroundColor: "#121212",
  },
  container: {
    flex: 1,
    padding: 20,
    backgroundColor: "#121212",
  },
  title: {
    fontSize: 24,
    fontWeight: "bold",
    color: "white",
    marginBottom: 20,
    textAlign: "center",
  },
  warningText: {
    fontSize: 16,
    color: "white",
    marginBottom: 20,
  },
  hallucinationText: {
    color: "red",
    fontWeight: "bold",
  },
  dropdownContainer: {
    backgroundColor: "#1e1e1e",
    padding: 10,
    borderRadius: 10,
    marginBottom: 20,
  },
  dropdownContainer2: {
    backgroundColor: "#1e1e1e",
    padding: 10,
    borderRadius: 10,
    marginBottom: 20,
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: "bold",
    color: "white",
    marginBottom: 10,
  },
  row: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 10,
  },
  labelText: {
    fontSize: 16,
    color: "white",
    marginRight: 10,
  },
  input: {
    flex: 1,
    height: 40,
    borderColor: "gray",
    borderWidth: 1,
    color: "white",
    marginBottom: 6,
    paddingHorizontal: 10,
    borderRadius: 5,
    backgroundColor: "#2e2e2e",
  },
  addButtonContainer: {
    alignItems: "flex-end",
  },
  generateButtonWrapper: {
    marginTop: 20,
    justifyContent: "center",
    alignItems: "center",
  },
  generateButtonContainer: {
    width: 200,
    height: 50,
    backgroundColor: "green",
    borderRadius: 10,
  },
  generateButton: {
    width: "100%",
    height: "100%",
    justifyContent: "center",
    alignItems: "center",
  },
  generateButtonText: {
    color: "white",
    fontWeight: "bold",
  },
  multipleSelectBoxStyles: {
    marginTop: 5,
    marginBottom: 5,
    borderColor: "white",
    backgroundColor: "#2e2e2e",
  },
  labelStyles: {
    color: "white",
  },
  dropdownTextStyles: {
    color: "white",
  },
  badgeStyles: {
    backgroundColor: "red",
  },
  placeholderStyles: {
    color: "gray",
  },
  selectedTextStyle: {
    color: "white",
  },
});

export default CheckIngredients;
