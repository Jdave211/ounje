import React, { useState, useEffect } from "react";
import { View, StyleSheet, TouchableOpacity, Text, Alert } from "react-native";
import axios from "axios";
import { FOOD_ITEMS } from "../utils/constants";
import {
  GENERATE_RECIPE_LIST_FROM_INGREDIENTS_PROMPT,
  GENERATE_RECIPES_PROMPT,
} from "../utils/prompts";
import { supabase } from "../utils/supabase";
import CaseConvert, { objectToSnake } from "ts-case-convert";
import { useNavigation } from "@react-navigation/native";
import { openai, extract_json } from "../utils/openai";
import { useAppStore, useTmpStore } from "../stores/app-store";
import { useRecipeOptionsStore } from "../stores/recipe-options-store";
import { find_recipes_by_ingredients } from "../utils/spoonacular";

export default function GenerateRecipes({
  onLoading,
  onRecipesGenerated,
  selectedMealType,
}) {
  const navigation = useNavigation();
  const [isLoading, setIsLoading] = useState(false);

  const userId = useAppStore((state) => state.user_id);
  const setRecipeOptions = useRecipeOptionsStore(
    (state) => state.setRecipeOptions
  );

  const getInventoryFoodItems = useAppStore(
    (state) => state.inventory.getFoodItems
  );

  const foodItems = getInventoryFoodItems();

  const generateGPTRecipes = async (foodItems, recipes_to_exclude) => {
    try {
      console.log("Generating recipes with GPT...");
      const foodItemNames = foodItems.map((item) => item.name).join(", ");
      console.log("Food Items:", foodItemNames);

      const food_item_names = foodItems.map((item) => item.name);
      const recipes_to_exclude_names = recipes_to_exclude.map(
        (recipe) => recipe.title
      );

      const generate_recipe_list_prompt = {
        role: "system",
        content: GENERATE_RECIPE_LIST_FROM_INGREDIENTS_PROMPT,
      };
      const recipe_list_request = {
        role: "user",
        content: `
        Ingredients: ${food_item_names.join(", ")}
        Exclude: ${recipes_to_exclude_names.join(", ")}
        meal_type: ${selectedMealType}
        `,
      };
      const {
        choices: [
          {
            message: { content: recipe_list_response_text },
          },
        ],
      } = await openai.chat.completions.create({
        model: "gpt-4o",
        messages: [generate_recipe_list_prompt, recipe_list_request],
        response_format: { type: "json_object" },
      });

      const recipe_list_response = JSON.parse(recipe_list_response_text);
      console.log({ recipe_list_response });

      const generate_recipe_details = async (recipe) => {
        const system_prompt = {
          role: "system",
          content: GENERATE_RECIPES_PROMPT,
        };
        const recipe_details_request = {
          role: "user",
          content: JSON.stringify(recipe),
        };

        const {
          choices: [
            {
              message: { content: recipe_details_response },
            },
          ],
        } = await openai.chat.completions.create({
          model: "gpt-4o",
          messages: [system_prompt, recipe_details_request],
          response_format: { type: "json_object" },
        });

        return JSON.parse(recipe_details_response);
      };

      const recipe_details = await Promise.allSettled(
        recipe_list_response.map(generate_recipe_details)
      );

      // Follow-up requests for different recipes
      for (let i = 0; i < 3; i++) {
        response = await openai.chat.completions.create({
          model: "gpt-4o",
          messages: [
            systemPrompt,
            userPrompt,
            {
              role: "user",
              content:
                "Give me another distinct recipe in JSON. In no way should it be related to the previous one(fruit salad -> apple fruit salad). instead do something like fruit salad -> apple pie",
            },
          ],
          response_format: { type: "json_object" },
        });
        console.log("Additional recipe", response.choices[0].message.content);
        recipes.push(JSON.parse(response.choices[0].message.content));
      }
      console.log("GPT Recipes", recipes);

      // Parse and format the GPT recipes
      const formattedRecipes = recipes.flat().map((recipe) => ({
        id: `gpt_${Math.random().toString(36).substr(2, 9)}`, // Unique ID for GPT recipes
        title: recipe.Recipe,
        summary: recipe.Summary,
        instructions: recipe.Instructions,
        ingredients: recipe.Ingredients,
        image: "", // Placeholder for image URL
        ready_in_minutes: recipe.CookTime,
        servings: recipe.Servings,
        calories: recipe.Calories,
      }));

      console.log("Formatted GPT Recipes:", formattedRecipes);

      // Generate DALL-E images for each recipe
      const recipesWithImages = await Promise.all(
        formattedRecipes.map(async (recipe) => {
          try {
            const response = await openai.images.generate({
              model: "dall-e-3",
              prompt: `A delicious dish of ${recipe.title}`,
              n: 1,
              size: "1024x1024",
            });
            recipe.image = response.data[0].url;
          } catch (error) {
            console.error("Error generating image for recipe:", error);
            recipe.image = ""; // Fallback to empty string if image generation fails
          }
          return recipe;
        })
      );

      return recipesWithImages;
    } catch (error) {
      console.error("Error generating recipes with GPT:", error);
      return [];
    }
  };

  const generateRecipes = async () => {
    console.log("Food Items:", foodItems);
    if (foodItems.length === 0) {
      Alert.alert(
        "Error",
        "Please add some food to inventory or take a new picture."
      );
      navigation.navigate("Inventory");
    } else {
      try {
        setIsLoading(true);
        onLoading(true);

        const selectedFoodItems = foodItems;

        const suggested_recipes = await find_recipes_by_ingredients(foodItems);

        await supabase
          .from("recipe_ids")
          .upsert(suggested_recipes, { onConflict: "id" });

        // Generate GPT recipes
        const gptRecipes = await generateGPTRecipes(
          selectedFoodItems,
          suggested_recipes
        );

        // Combine GPT recipes with Spoonacular recipes
        const allRecipes = [
          //...suggested_recipes,
          ...gptRecipes,
        ];

        setRecipeOptions(allRecipes); // Update the temporary state with the combined recipes
        console.log("All Recipes:", allRecipes);
      } catch (error) {
        console.error("Error generating recipes:", error);
        Alert.alert("Error", "Failed to generate recipes.");
      } finally {
        setIsLoading(false);
        onLoading(false);
        navigation.navigate("RecipeOptions");
      }
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
    width: 200,
    height: 50,
    backgroundColor: "#282C35",
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
    marginBottom: 20,
  },
  buttonText: {
    color: "#fff",
    fontWeight: "bold",
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
