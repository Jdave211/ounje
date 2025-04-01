import React, { useState } from "react";
import { View, StyleSheet, TouchableOpacity, Text, Alert, ActivityIndicator } from "react-native";
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
    // Check if user is logged in
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

    // Check if meal type is selected
    if (!selectedMealType) {
      Alert.alert(
        "Meal Type Required",
        "Please select what type of meal you're interested in (Breakfast, Lunch, Dinner, or Snack).",
      );
      return;
    }
  
    // Check if inventory has items
    if (foodItems.length === 0) {
      Alert.alert(
        "Empty Inventory",
        "Your inventory is empty. Would you like to add some ingredients?",
        [
          {
            text: "Cancel",
            style: "cancel",
          },
          {
            text: "Add Ingredients",
            onPress: () => navigation.navigate("Inventory"),
          },
        ]
      );
      return;
    }

    try {
      setIsLoading(true);
      onLoading(true);

      // Step 1: Find recipes based on ingredients
      let stored_suggested_recipes, new_suggested_recipes;
      try {
        const result = await find_recipes_by_ingredients(foodItems);
        stored_suggested_recipes = result.stored_suggested_recipes;
        new_suggested_recipes = result.new_suggested_recipes;
        console.log(`Found ${new_suggested_recipes.length} new recipes and ${stored_suggested_recipes.length} existing recipes`);
      } catch (error) {
        console.error("Error finding recipes:", error);
        throw new Error("Failed to find recipes with your ingredients. Please try again.");
      }
  
      // Step 2: Store new recipes
      let new_stored_recipes;
      try {
        const { data, error } = await supabase
          .from("recipe_ids")
          .upsert(new_suggested_recipes, {
            onConflict: "spoonacular_id",
          })
          .select();
        
        if (error) throw error;
        new_stored_recipes = data;
      } catch (error) {
        console.error("Error storing recipes:", error);
        throw new Error("Failed to save new recipes. Please try again.");
      }
  
      // Step 3: Process and filter recipes
      const total_recipes = [...stored_suggested_recipes, ...new_stored_recipes];
      
      // Remove duplicates and null values
      const unique_total_recipes = Array.from(
        new Set(total_recipes
          .filter(recipe => recipe !== null)
          .map(recipe => recipe?.spoonacular_id))
      )
      .map(id => total_recipes.find(recipe => recipe && recipe?.spoonacular_id === id))
      .filter(recipe => recipe !== null);
  
      if (unique_total_recipes.length === 0) {
        throw new Error("No recipes found with your current ingredients. Try adding more ingredients to your inventory.");
      }

      setRecipeOptions(unique_total_recipes);
      
      // Show success message with recipe count
      Alert.alert(
        "Success!",
        `Found ${unique_total_recipes.length} recipes you can make with your ingredients.`,
        [
          {
            text: "View Recipes",
            onPress: () => navigation.navigate("RecipeOptions"),
          },
        ]
      );

    } catch (error) {
      console.error("Error generating recipes:", error);
      Alert.alert(
        "Recipe Generation Error",
        error.message || "Failed to generate recipes. Please try again."
      );
    } finally {
      setIsLoading(false);
      onLoading(false);
    }
  };
  
  
  return (
    <View style={styles.container}>
      <TouchableOpacity
        style={[
          styles.buttonContainer,
          isLoading && styles.buttonDisabled
        ]}
        onPress={generateRecipes}
        disabled={isLoading}
      >
        {isLoading ? (
          <View style={styles.loadingContainer}>
            <ActivityIndicator color="#fff" style={styles.spinner} />
            <Text style={styles.buttonText}>Finding Recipes...</Text>
          </View>
        ) : (
          <Text style={styles.buttonText}>Generate Recipes</Text>
        )}
      </TouchableOpacity>
      {isLoading && (
        <Text style={styles.loadingText}>
          Analyzing your ingredients to find the perfect recipes...
        </Text>
      )}
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
  buttonDisabled: {
    backgroundColor: "#1a1d22", // Darker shade when disabled
    opacity: 0.9,
  },
  loadingContainer: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
  },
  spinner: {
    marginRight: 10,
  },
  buttonText: {
    color: "#fff",
    fontWeight: "bold",
    fontSize: 18,
  },
  loadingText: {
    color: "#fff",
    marginTop: 10,
    fontSize: 14,
    textAlign: "center",
    opacity: 0.8,
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