import React, { useState, useEffect } from "react";
import {
  View,
  StyleSheet,
  TouchableOpacity,
  Text,
  Alert,
  ScrollView,
  Modal,
} from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import axios from "axios";
import { openai } from "../utils/openai"; // Adjust this import based on your project structure
import { RECIPES_PROMPT } from "../utils/prompts"; // Adjust this import based on your project structure
import { FOOD_ITEMS } from "../utils/constants";
import { useNavigation } from "@react-navigation/native";
import { supabase } from "../utils/supabase";
import CaseConvert, { objectToSnake } from "ts-case-convert";

export default function GenerateRecipes({ onLoading, onRecipesGenerated }) {
  const navigation = useNavigation();

  const [isLoading, setIsLoading] = useState(false);
  const [recipes, setRecipes] = useState([]);
  const [gptResults, setGptResults] = useState([]);
  const [modalVisible, setModalVisible] = useState(false);
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

  const fetchRecipes = async () => {
    try {
      setIsLoading(true);
      onLoading(true);

      const storedFoodItems = await AsyncStorage.getItem("food_items_array");
      if (storedFoodItems) {
        const foodItemsArray = JSON.parse(storedFoodItems).map(
          (item) => item.name || item,
        );
        const ingredients = foodItemsArray.join(", ");

        const response = await axios.get(
          "https://api.spoonacular.com/recipes/findByIngredients",
          {
            params: {
              ingredients,
              number: 2,
              ranking: 1,
              ignorePantry: "false",
              apiKey: process.env.SPOONACULAR_API_KEY,
            },
          },
        );

        const recipesWithDetails = await Promise.all(
          response.data.map(async (recipe) => {
            const recipeDetails = await fetchRecipeDetails(recipe.id);
            return { ...recipe, details: recipeDetails };
          }),
        );

        setRecipes(recipesWithDetails);

        const gptResponses = await Promise.all(
          recipesWithDetails.map(
            async (recipe) =>
              await passRecipeThroughGPT(recipe, foodItemsArray),
          ),
        );

        setGptResults(gptResponses);
      } else {
        Alert.alert("Error", "No food items found in inventory.");
      }
    } catch (error) {
      console.error("Error fetching recipes:", error);
      Alert.alert("Error", "Unable to fetch recipes.");
    } finally {
      setIsLoading(false);
      onLoading(false);
      onRecipesGenerated(recipes);
      setModalVisible(true);
    }
  };

  const fetchRecipeDetails = async (recipeId) => {
    try {
      const response = await axios.get(
        `https://api.spoonacular.com/recipes/${recipeId}/information`,
        {
          params: {
            includeNutrition: true,
            apiKey: process.env.SPOONACULAR_API_KEY,
          },
        },
      );
      return response.data;
    } catch (error) {
      console.error(`Error fetching details for recipe ID ${recipeId}:`, error);
      return null;
    }
  };

  const passRecipeThroughGPT = async (recipe, foodItems) => {
    try {
      const recipeText = `
        Recipe: ${recipe.title}
        Cook Time: ${recipe.details.readyInMinutes} minutes
        Servings: ${recipe.details.servings}
        Calories: ${recipe.details.nutrition.nutrients[0].amount} kcal
        Ingredients: ${recipe.details.extendedIngredients
          .map((ingredient) => ingredient.original)
          .join(", ")}
        Instructions: ${recipe.details.instructions}
        Summary: ${recipe.details.summary}
      `;

      const systemPrompt = { role: "system", content: RECIPES_PROMPT };
      const userPrompt = {
        role: "user",
        content: `Food Items: ${foodItems.join(", ")}\nRecipe:\n${recipeText}`,
      };

      const response = await openai.chat.completions.create({
        model: "gpt-3.5-turbo-0125:personal:ounje2:9T4gBMe8",
        messages: [systemPrompt, userPrompt],
      });

      return response.choices[0].message.content;
    } catch (error) {
      console.error("Error passing recipe through GPT:", error);
      return "Error validating recipe.";
    }
  };

  const generateRecipes = async () => {
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

      await AsyncStorage.setItem(
        "recipe_options",
        JSON.stringify(recipeOptionsInSnakeCase),
      );
      navigation.navigate("RecipeOptions");
    } catch (error) {
      console.error("Error generating recipes:", error);
      Alert.alert("Error", "Failed to generate recipes.");
    } finally {
      setIsLoading(false);
      onLoading(false);
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
    backgroundColor: "green",
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
    marginBottom: 20,
  },
  buttonText: {
    color: "#fff",
    fontWeight: "bold",
  },
  scrollContainer: {
    width: "100%",
    paddingHorizontal: 20,
  },
  recipeContainer: {
    marginBottom: 20,
    padding: 15,
    borderRadius: 10,
    backgroundColor: "#f8f8f8",
  },
  recipeTitle: {
    fontSize: 18,
    fontWeight: "bold",
    marginBottom: 10,
  },
  recipeDetails: {
    marginTop: 10,
  },
  recipeText: {
    fontSize: 14,
    marginBottom: 5,
  },
  gptContainer: {
    marginTop: 20,
    padding: 15,
    borderRadius: 10,
    backgroundColor: "#e8e8e8",
  },
  gptTitle: {
    fontSize: 18,
    fontWeight: "bold",
    marginBottom: 10,
  },
  gptText: {
    fontSize: 14,
  },
});
