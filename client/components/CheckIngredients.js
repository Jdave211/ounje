import React, { useState } from "react";
import { View, Text, TextInput, Button, StyleSheet } from "react-native";
import { MultipleSelectList } from "../components/MultipleSelectList";

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
            setSelected={(val) => setSelected(val)}
            data={data}
            save="value"
            search={false}
            label="Remove Ingredients"
            labelStyles={{ color: "white" }}
            dropdownTextStyles={{ color: "white" }}
            badgeStyles={{ backgroundColor: "red" }}
          />
        </View>
        <View style={styles.dropdownContainer}>
          <TextInput
            style={styles.input}
            placeholder="Include Ingredients"
            value={inputValue}
            onChangeText={setInputValue}
            placeholderTextColor="white"
          />
          <Button title="Add Ingredient" onPress={handleAddIngredient} />
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
    marginBottom: 20,
  },
  input: {
    height: 40,
    borderColor: "gray",
    borderWidth: 1,
    color: "white",
    marginBottom: 10,
    paddingHorizontal: 10,
  },
});

export default CheckIngredients;
