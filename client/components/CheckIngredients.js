import React, { useState } from "react";
import {
  View,
  Text,
  TextInput,
  Button,
  StyleSheet,
  TouchableOpacity,
} from "react-native";
import MultipleSelectList from "../components/MultipleSelectList";

const CheckIngredients = () => {
  const [selected, setSelected] = useState([]);
  const [data, setData] = useState([
    { key: "1", value: "Rice" },
    { key: "2", value: "Eggs" },
    { key: "3", value: "Ostrich head" },
  ]);
  const [inputValue, setInputValue] = useState("");

  const handleAddIngredient = () => {
    if (inputValue.trim()) {
      const newIngredient = {
        key: (data.length + 1).toString(),
        value: inputValue.trim(),
      };
      setData([...data, newIngredient]);
      setInputValue("");
    }
    alert("Ingredient added.");
  };

  const handleRemoveIngredient = () => {
    const newData = data.filter((item) => !selected.includes(item.key));
    setData(newData);
    setSelected([]);
    alert("Selected ingredients removed.");
  };

  return (
    <View style={styles.container}>
      <View>
        <Text style={styles.warningText}>
          The model we are currently using is prone to{" "}
          <Text style={{ color: "red", fontWeight: "bold" }}>
            hallucination.
          </Text>{" "}
          Please double-check your food items.
        </Text>
        <View style={styles.dropdownContainer}>
          <MultipleSelectList
            setSelected={setSelected}
            data={data}
            selected={selected}
            save="key"
            search={false}
            label="Remove Ingredients"
            labelStyles={{ color: "white" }}
            dropdownTextStyles={{ color: "white" }}
            badgeStyles={{ backgroundColor: "red" }}
          />
          <View style={styles.addButtonContainer}>
            <Button
              title="remove"
              color="red"
              onPress={handleRemoveIngredient}
            />
          </View>
        </View>
        <View style={styles.dropdownContainer2}>
          <TextInput
            style={styles.input}
            placeholder="Add Ingredients"
            value={inputValue}
            onChangeText={setInputValue}
            placeholderTextColor="white"
            autoCapitalize="none"
          />
          <View style={styles.addButtonContainer}>
            <Button title="add" color="green" onPress={handleAddIngredient} />
          </View>
        </View>
      </View>
      <View style={styles.generateButtonWrapper}>
        <View style={styles.generateButtonContainer}>
          <TouchableOpacity
            style={styles.generateButton}
            disabled={data.length === 0}
          >
            <Text style={styles.generateButtonText}>Generate Recipes</Text>
          </TouchableOpacity>
        </View>
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 20,
    backgroundColor: "black",
  },
  warningText: {
    fontSize: 16,
    color: "white",
    marginBottom: 10,
  },
  dropdownContainer: {
    backgroundColor: "black",
  },
  dropdownContainer2: {
    backgroundColor: "black",
    marginTop: 20,
    marginBottom: 20,
  },
  input: {
    height: 40,
    borderColor: "gray",
    borderWidth: 1,
    color: "white",
    marginBottom: 6,
    paddingHorizontal: 10,
  },
  addButtonContainer: {
    alignItems: "flex-end",
  },
  generateButtonWrapper: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
  },
  generateButtonContainer: {
    width: "80%", // Adjust this as needed
    height: 50,
    backgroundColor: "green",
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
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
});

export default CheckIngredients;
