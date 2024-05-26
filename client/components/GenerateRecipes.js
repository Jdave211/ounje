import React, { useState, useEffect } from "react";
import {
  View,
  StyleSheet,
  TouchableOpacity,
  Text,
  Alert,
  ScrollView,
  ActivityIndicator,
  Modal
} from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import axios from "axios";
import { openai } from "../utils/openai"; // Adjust this import based on your project structure
import { RECIPES_PROMPT } from "../utils/prompts"; // Adjust this import based on your project structure
import RecipeCard from './RecipeCard'; // Adjust this import based on your project structure

export default function GenerateRecipes({ onLoading, onRecipesGenerated }) {
  const [isLoading, setIsLoading] = useState(false);
  const [recipes, setRecipes] = useState([]);
  const [gptResults, setGptResults] = useState([]);
  const [modalVisible, setModalVisible] = useState(false);


  const handleRecipesReady = () => {
    setModalVisible(true);
  };

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
            number: 2,
            ranking: 1,
            ignorePantry: 'false',
            apiKey: process.env.SPOONACULAR_API_KEY,
          },
        });

        const recipesWithDetails = await Promise.all(
          response.data.map(async (recipe) => {
            const recipeDetails = await fetchRecipeDetails(recipe.id);
            return { ...recipe, details: recipeDetails };
          })
        );

        setRecipes(recipesWithDetails);
        console.log("Recipes with details:", recipesWithDetails);

        // Pass each recipe to OpenAI for validation
        const gptResponses = await Promise.all(
          recipesWithDetails.map(async (recipe) => await passRecipeThroughGPT(recipe, foodItems))
        );

        setGptResults(gptResponses);
        console.log("GPT Results:", gptResponses);
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
      const response = await axios.get(`https://api.spoonacular.com/recipes/${recipeId}/information`, {
        params: {
          includeNutrition: true,
          apiKey: process.env.SPOONACULAR_API_KEY,
        },
      });
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
        Ingredients: ${recipe.details.extendedIngredients.map((ingredient) => ingredient.original).join(", ")}
        Instructions: ${recipe.details.instructions}
        Summary: ${recipe.details.summary}
      `;

      const system_prompt = { role: "system", content: RECIPES_PROMPT };
      const user_prompt = { role: "user", content: `Food Items: ${foodItems.join(", ")}\nRecipe:\n${recipeText}` };

      console.log("Sending prompts to OpenAI:", system_prompt, user_prompt);

      const response = await openai.chat.completions.create({
        model: "ft:gpt-3.5-turbo-0125:personal:ounje2:9T4gBMe8",
        messages: [system_prompt, user_prompt],
      });

      console.log("OpenAI response:", response.choices[0].message.content);
      return response.choices[0].message.content;

    } catch (error) {
      console.error("Error passing recipe through GPT:", error);
      return "Error validating recipe.";
    }
    setIsLoading(false);
  };

  return (
    <View style={styles.container}>
      <TouchableOpacity
        style={styles.buttonContainer}
        onPress={fetchRecipes}
        disabled={isLoading}
      >
        <Text style={styles.buttonText}>Generate Recipes</Text>
      </TouchableOpacity>
      <Modal
          animationType="slide"
          transparent={false}
          visible={modalVisible}
          onRequestClose={() => {
            setModalVisible(!modalVisible);
          }}
        >
      <ScrollView style={styles.scrollContainer}>
        {gptResults.map((result, index) => (
          <View key={index} style={styles.gptContainer}>
            <Text style={styles.gptTitle}>GPT Validation for Recipe {index + 1}:</Text>
            <Text style={styles.gptText}>{result}</Text>
          </View>
        ))}
      </ScrollView>
      </Modal>
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
