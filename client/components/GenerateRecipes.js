import React, { useState, useEffect } from "react";
import { View, StyleSheet, TouchableOpacity, Text, Alert } from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import axios from "axios";
import { FOOD_ITEMS } from "../utils/constants";
import { GENERATE_RECIPES_PROMPT } from "../utils/prompts";
import { supabase } from "../utils/supabase";
import CaseConvert, { objectToSnake } from "ts-case-convert";
import { useNavigation } from "@react-navigation/native";
import { openai, extract_json } from "../utils/openai";

export default function GenerateRecipes({ onLoading, onRecipesGenerated }) {
  const navigation = useNavigation();
  const [isLoading, setIsLoading] = useState(false);
  const [recipes, setRecipes] = useState([]);
  const [userId, setUserId] = useState(null);
  const [foodItems, setFoodItems] = useState([]);

  useEffect(() => {
    const fetchData = async () => {
      try {
        const userId = await AsyncStorage.getItem("user_id");
        if (userId) setUserId(userId);

        const storedFoodItems = await AsyncStorage.getItem("food_items_array");
        if (storedFoodItems) setFoodItems(JSON.parse(storedFoodItems));
      } catch (error) {
        console.error("Error fetching user data:", error);
        Alert.alert("Error", "Failed to fetch user data.");
      }
    };

    fetchData();
  }, []);

  const generateGPTRecipes = async (foodItems) => {
    try {
      console.log("Generating recipes with GPT...");
      const foodItemNames = foodItems.map((item) => item.name).join(", ");
      console.log("Food Items:", foodItemNames);

      const systemPrompt = { role: "system", content: GENERATE_RECIPES_PROMPT };
      const userPrompt = {
        role: "user",
        content: `Food Items: ${foodItemNames}`,
      };

      // Initial request
      let response = await openai.chat.completions.create({
        model: "gpt-4o",
        messages: [systemPrompt, userPrompt],
        response_format: { type: "json_object" },
      });
      console.log(response);
      let recipes = [JSON.parse(response.choices[0].message.content)];

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
        }),
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
        "Please add some food to inventory or take a new picture.",
      );
      navigation.navigate("Inventory");
    } else {
      try {
        setIsLoading(true);
        onLoading(true);

        const { data: runs, error: runsError } = await supabase
          .from("runs")
          .insert([{ user_id: userId, images: [] }]) // Ensure images is set to an empty array or appropriate default value
          .select();

        if (runsError) {
          console.error("Error adding user run:", runsError);
          Alert.alert("Error", "Failed to add user run.");
          return;
        }

        const currentRun = runs[0];

        const selectedFoodItems = foodItems.map((item) => ({
          run_id: currentRun.id,
          ...item,
        }));

        await supabase.from("food_items").upsert(selectedFoodItems);

        const { data: suggestedRecipes } = await axios.get(
          "https://api.spoonacular.com/recipes/findByIngredients",
          {
            params: {
              apiKey: process.env.SPOONACULAR_API_KEY,
              ingredients: foodItems.map(({ name }) => name).join(", "),
              number: 7,
              ranking: 1,
            },
          },
        );

        const { data: recipeDetails } = await axios.get(
          `https://api.spoonacular.com/recipes/informationBulk`,
          {
            params: {
              apiKey: process.env.SPOONACULAR_API_KEY,
              includeNutrition: true,
              ids: suggestedRecipes.map((recipe) => recipe.id).join(", "),
            },
          },
        );

        const recipeOptions = suggestedRecipes.map((suggestedRecipe, i) => ({
          ...suggestedRecipe,
          ...recipeDetails[i],
        }));

        const recipeOptionsInSnakeCase = objectToSnake(recipeOptions).map(
          (recipe) => {
            delete recipe.cheap;
            delete recipe.gaps;
            delete recipe.likes;
            delete recipe.missed_ingredient_count;
            delete recipe.missed_ingredients;
            delete recipe.used_ingredients;
            delete recipe.used_ingredient_count;
            delete recipe.user_tags;
            delete recipe.unused_ingredients;
            delete recipe.unknown_ingredients;
            delete recipe.open_license;
            delete recipe.report;
            delete recipe.suspicious_data_score;
            delete recipe.tips;
            return recipe;
          },
        );

        await supabase
          .from("recipe_ids")
          .upsert(recipeOptionsInSnakeCase, { onConflict: "id" });

        // Generate GPT recipes
        const gptRecipes = await generateGPTRecipes(selectedFoodItems);

        // Combine GPT recipes with Spoonacular recipes
        const allRecipes = [...recipeOptionsInSnakeCase, ...gptRecipes];

        // Store combined recipes to AsyncStorage
        await AsyncStorage.setItem(
          "recipe_options",
          JSON.stringify(allRecipes),
        );
        console.log("All Recipes:", allRecipes);

        setRecipes(allRecipes); // Update the state with the combined recipes
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
