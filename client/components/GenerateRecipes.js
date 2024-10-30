import React, { useState } from "react";
import { View, StyleSheet, TouchableOpacity, Text, Alert } from "react-native";
import { useNavigation } from "@react-navigation/native";
import { useAppStore, useTmpStore } from "../stores/app-store";
import { useRecipeOptionsStore } from "../stores/recipe-options-store";
import { supabase, generate_and_store_image } from "../utils/supabase";
import {
  GENERATE_RECIPE_LIST_FROM_INGREDIENTS_PROMPT,
  GENERATE_RECIPE_DETAILS_PROMPT_V2,
} from "../utils/prompts";
import { openai } from "../utils/openai";
import { find_recipes_by_ingredients } from "../utils/spoonacular";
import { nanoid } from "nanoid/non-secure";

export default function GenerateRecipes({ onLoading, onRecipesGenerated }) {
  const navigation = useNavigation();
  const [isLoading, setIsLoading] = useState(false);

  const userId = useAppStore((state) => state.user_id);
  const setUserId = useAppStore((state) => state.set_user_id); // Add this line
  const setRecipeOptions = useRecipeOptionsStore(
    (state) => state.setRecipeOptions,
  );

  const selectedMealType = useRecipeOptionsStore(
    (state) => state.dish_types[0],
  );

  const getInventoryFoodItems = useAppStore(
    (state) => state.inventory.getFoodItems,
  );

  const foodItems = getInventoryFoodItems();

  const generateGPTRecipes = async (foodItems, recipes_to_exclude) => {
    // ... (existing code for generateGPTRecipes)
  };

  
  const generateRecipes = async () => {
    if (userId.startsWith("guest")) {
      Alert.alert(
        "Authentication Required",
        "You need to be logged in with an inventory to generate recipes.",
        [
          {
            text: "Cancel",
            style: "cancel",
          },
          {
            text: "Sign In / Sign Up",
            onPress: () => {
              setUserId(null);
            },
          },
        ],
        { cancelable: true },
      );
      return;
    }
  
    if (foodItems.length === 0) {
      Alert.alert(
        "Error",
        "Please add some food to inventory or take a new picture.",
      );
      navigation.navigate("Inventory");
      return;
    }

    try { 
      setIsLoading(true); 
      onLoading(true);
  
      const { stored_suggested_recipes, new_suggested_recipes } =
          await find_recipes_by_ingredients(foodItems);
  
      // Upsert only new suggested recipes
      const { data: new_stored_recipes } = await supabase
          .from("recipe_ids")
          .upsert(new_suggested_recipes, {
              onConflict: "spoonacular_id",
          })
          .select()
          .throwOnError();
  
      const total_recipes = [
          ...stored_suggested_recipes,
          ...new_stored_recipes,
      ];
  
      // Log total_recipes to check for null values
      // console.log("Total Recipes:", total_recipes);
  
      // Remove duplicates by spoonacular_id and filter out null values
      const unique_total_recipes = Array.from(
          new Set(total_recipes
              .filter(recipe => recipe !== null) // First filter out nulls
              .map(recipe => recipe?.spoonacular_id)) // Then map to spoonacular_id
      ).map(id => total_recipes.find(recipe => recipe && recipe?.spoonacular_id === id)) // Ensure recipe is not null here
        .filter(recipe => recipe !== null); // Final filter to remove null values
  
      setRecipeOptions(unique_total_recipes);
      // console.log("Unique Total Recipes:", unique_total_recipes);
  } catch (error) {
      console.error("Error generating recipes:", error);
      console.trace(error);
      Alert.alert("Error", "Failed to generate recipes.");
  } finally {
      setIsLoading(false);
      onLoading(false);
      navigation.navigate("RecipeOptions");
  }
    
  };
  
  
  return (
    <View style={styles.container}>
      <TouchableOpacity
        style={styles.buttonContainer}
        onPress={generateRecipes}
        disabled={isLoading}
      >
        <Text style={styles.buttonText}>Generate Recipes</Text>
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    marginTop: 20,
  },
  buttonContainer: {
    width: 275,
    height: 50,
    backgroundColor: "#282C35",
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
    
  },
  buttonText: {
    color: "#fff",
    fontWeight: "bold",
    fontSize: 18,
  },
  closeButton: {
    marginTop: 20,
    padding: 15,
    borderRadius: 10,
    backgroundColor: "red",
    justifyContent: "center",
    alignItems: "center",
  },
  closeButtonText: {
    color: "#fff",
    fontWeight: "bold",
  },
});