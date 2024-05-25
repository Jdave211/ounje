import React, { useState } from "react";
import {
  Button,
  Image,
  View,
  StyleSheet,
  TouchableOpacity,
  Text,
  Alert,
} from "react-native";
import * as ImagePicker from "expo-image-picker";
import * as FileSystem from "expo-file-system";
import Constants from "expo-constants";
import { ActionSheetIOS } from "react-native";
import { Linking } from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { FOOD_ITEMS } from "../utils/constants";
import { RECIPES_PROMPT } from "@utils/prompts";
import { customAlphabet } from "nanoid/non-secure";
import { Buffer } from "buffer";
import axios from "axios";

import { FOOD_ITEMS_PROMPT } from "../utils/prompts";
import { openai, extract_json, flatten_nested_objects } from "../utils/openai";
import { supabase, store_image } from "../utils/supabase";
import { generate_image } from "../utils/stability";
const nanoid = customAlphabet("abcdefghijklmnopqrstuvwxyz0123456789", 10);

export default function GenerateRecipes({ onLoading }) {
  const [isLoading, setIsLoading] = useState(false);
  const [recipes, setRecipes] = useState([]);

  const fetchRecipes = async () => {
    try {
      setIsLoading(true);
      onLoading(true);
      // Fetch food items from AsyncStorage
      const storedFoodItems = await AsyncStorage.getItem("food_items");
      if (storedFoodItems) {
        const foodItems = JSON.parse(storedFoodItems);
        const ingredients = foodItems.join(", ");
        console.log("Ingredients:", ingredients);

        // Call Spoonacular API to fetch recipes
        const response = await axios.get("https://api.spoonacular.com/recipes/findByIngredients", {
          params: {
            ingredients: ingredients,
            instructionsRequired: 'true',
            addRecipeNutrition: 'true',
            number: 3,
            ranking: 1,
            ignorePantry: 'false',
            apiKey:'bb9552487f8d42d381557fa5a3754d52',
            // process.env.SPOONACULAR_API_KEY
          },
        });
        setRecipes(response.data);
        console.log("Recipes:", response.data);
      } else {
        Alert.alert("Error", "No food items found in inventory.");
      }
    } catch (error) {
      console.error("Error fetching recipes:", error);
      Alert.alert("Error", "Unable to fetch recipes.");
    } finally {
      setIsLoading(false);
      onLoading(false);
    }
  };

  return (
    <View style={styles.container}>
      <View style={styles.buttonContainer}>
        <TouchableOpacity
          style={styles.buttonContainer}
          onPress={() => {
            fetchRecipes();
          }}
        >
          <Text style={styles.buttonText}>Generate</Text>
        </TouchableOpacity>
      </View>
      </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: "center",
    justifyContent: "center",
    marginTop: 20,
  },
  buttonContainer: {
    width: 200,
    height: 50,
    backgroundColor: "green",
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
  },
  buttonText: {
    color: "#fff",
    fontWeight: "bold",
  },
});
