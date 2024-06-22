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
  const [gptResults, setGptResults] = useState([]);
  const [userId, setUserId] = useState(null);
  const [foodItems, setFoodItems] = useState(FOOD_ITEMS);

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

      const response = await openai.chat.completions.create({
        model: "gpt-4o",
        messages: [systemPrompt, userPrompt],
        response_format: { type: "json_object" },
      });

      console.log("GPT Response:", response);
      return response;
    } catch (error) {
      console.error("Error passing recipe through GPT:", error);
      return "Error validating recipe.";
    }
  };

  const generateRecipes = async () => {
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
        await generateGPTRecipes(selectedFoodItems);

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

        await AsyncStorage.setItem(
          "recipe_options",
          JSON.stringify(recipeOptionsInSnakeCase),
        );
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
