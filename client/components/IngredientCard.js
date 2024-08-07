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
      <Text style={styles.ingredientText}>{entitle(name)}</Text>
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
    height: 120,
    alignItems: "center",
    padding: 10,
    borderRadius: 10,
    marginRight: 10,
    marginBottom: 10,
    position: "relative",
    backgroundColor: "transparent", // No background for the whole card
  },
  cancelButton: {
    position: "absolute",
    top: 5,
    right: 5,
    borderRadius: 15,
    width: 24,
    height: 24,
    alignItems: "center",
    justifyContent: "center",
    zIndex: 1,
  },
  imageContainer: {
    width: 80,
    height: 80,
    borderRadius: 10,
    backgroundColor: "rgba(0, 0, 0, 0.2)", // Background for the image container
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 10,
  },
  ingredientImage: {
    width: 60,
    height: 60,
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
    marginTop: 5,
    textAlign: "center",
  },
});

export default IngredientCard;
