import React from "react";
import { View, Text, Image, StyleSheet, TouchableOpacity } from "react-native";
import { MaterialIcons } from "@expo/vector-icons";
import { entitle } from "../utils/helpers";

const IngredientCard = ({
  name,
  image,
  amount,
  unit,
  onCancel,
  showCancelButton = false,
}) => {
  // Split the name into words and determine the number of lines
  const words = entitle(name).split(" ");
  const numberOfLines = words.length > 1 ? 2 : 1;

  return (
    <View style={styles.ingredient}>
      {showCancelButton && (
        <TouchableOpacity style={styles.cancelButton} onPress={onCancel}>
          <MaterialIcons name="cancel" size={18} color="white" />
        </TouchableOpacity>
      )}
      <View style={styles.imageContainer}>
        <Image style={styles.ingredientImage} source={{ uri: image }} />
      </View>
      <Text
        style={styles.ingredientText}
        adjustsFontSizeToFit
        numberOfLines={numberOfLines}
      >
        {entitle(name)}
      </Text>
      {amount !== undefined && unit !== undefined && (
        <Text style={styles.ingredientAmount}>
          {amount} {unit}
        </Text>
      )}
    </View>
  );
};

const styles = StyleSheet.create({
  ingredient: {
    width: 100,
    height: 130,
    alignItems: "center",
    padding: 10,
    borderRadius: 10,
    marginRight: 10,
    marginBottom: 10,
    position: "relative",
    backgroundColor: "transparent",
  },
  cancelButton: {
    position: "absolute",
    top: 13,
    right: 13,
    borderRadius: 15,
    width: 24,
    height: 24,
    alignItems: "center",
    justifyContent: "center",
    zIndex: 1,
    backgroundColor: "rgba(0, 0, 0, 0.3)",
  },
  imageContainer: {
    width: 80,
    height: 80,
    borderRadius: 10,
    backgroundColor: "rgba(0, 0, 0, 0.2)",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 4,
  },
  ingredientImage: {
    width: 50,
    height: 50,
    borderRadius: 10,
  },
  ingredientText: {
    fontSize: 14,
    fontWeight: "600",
    color: "white",
    textAlign: "center",
  },
  ingredientAmount: {
    fontSize: 12,
    color: "gray",
    marginTop: 3,
    textAlign: "center",
  },
});

export default IngredientCard;
