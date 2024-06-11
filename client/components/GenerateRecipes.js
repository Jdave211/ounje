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
import RecipeCard from "./RecipeCard"; // Adjust this import based on your project structure
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
  const [user_id, setUserId] = useState(null);
  const [food_items, setFoodItems] = useState(FOOD_ITEMS);
  const [food_items_array, setFoodItemsArray] = useState([]);

  useEffect(() => {
    const get_user_id = async () => {
      let retrieved_user_id = await AsyncStorage.getItem("user_id");
      setUserId(() => retrieved_user_id);
    };

    const fetch_food_items = async () => {
      let retrieved_text = await AsyncStorage.getItem("food_items");
      let retrieved_food_items = JSON.parse(retrieved_text);

      retrieved_text = await AsyncStorage.getItem("food_items_array");
      let retrieved_food_items_array = JSON.parse(retrieved_text);

      if (retrieved_food_items) {
        setFoodItems(() => retrieved_food_items);
      }

      if (retrieved_food_items_array?.length > 0) {
        setFoodItemsArray(() => retrieved_food_items_array);
      }
      console.log({ retrieved_food_items_array });
    };

    console.log("running useEffect");
    if (!user_id) {
      get_user_id();
      fetch_food_items();
    } else {
      fetch_food_items();
    }
  }, []);

  const handleRecipesReady = () => {
    setModalVisible(true);
  };

  const fetchRecipes = async () => {
    try {
      setIsLoading(true);
      onLoading(true);

      // Fetch food items from AsyncStorage
      const storedFoodItems = await AsyncStorage.getItem("food_items_array");

      if (storedFoodItems) {
        const foodItems = JSON.parse(storedFoodItems).map(
          (item) => item.name || item,
        );
        const ingredients = foodItems.join(", ");
        console.log("Ingredients:", ingredients);

        // Call Spoonacular API to fetch recipes
        const response = await axios.get(
          "https://api.spoonacular.com/recipes/findByIngredients",
          {
            params: {
              ingredients: ingredients,
              number: 2,
              ranking: 1,
              ignorePantry: "false",
              apiKey: process.env.SPOONACULAR_API_KEY,
            },
          },
        );

        console.log({ response });

        const recipesWithDetails = await Promise.all(
          response.data.map(async (recipe) => {
            const recipeDetails = await fetchRecipeDetails(recipe.id);
            return { ...recipe, details: recipeDetails };
          }),
        );

        setRecipes(recipesWithDetails);
        console.log("Recipes with details:", recipesWithDetails);

        // Pass each recipe to OpenAI for validation
        const gptResponses = await Promise.all(
          recipesWithDetails.map(
            async (recipe) => await passRecipeThroughGPT(recipe, foodItems),
          ),
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

      const system_prompt = { role: "system", content: RECIPES_PROMPT };
      const user_prompt = {
        role: "user",
        content: `Food Items: ${foodItems.join(", ")}\nRecipe:\n${recipeText}`,
      };

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

  const generate_recipes = async () => {
    let async_run_response = supabase
      .from("runs")
      .insert([{ user_id }])
      .select()
      .throwOnError();

    const [
      {
        value: { data: runs, error: runs_error },
      },
    ] = await Promise.allSettled([async_run_response]);

    setIsLoading(true);
    if (runs_error) console.log("Error:", runs_error);
    else console.log("Added User Run:", runs);

    console.log("runs: ", runs);
    current_run = runs[runs.length - 1];

    console.log("current_run: ", current_run);

    // let selected_set = new Set(selected);
    const selected_food_items = food_items_array.filter(
      (item) =>
        // selected_set.has(item.name),
        true,
    );
    const food_item_records = selected_food_items.map((record) => ({
      run_id: current_run.id,
      ...record,
    }));

    console.log("food_item_records: ", food_item_records);

    await supabase.from("food_items").upsert(food_item_records).throwOnError();

    console.log("starting recipes");

    const { data: suggested_recipes } = await axios
      .get("https://api.spoonacular.com/recipes/findByIngredients", {
        params: {
          apiKey: process.env.SPOONACULAR_API_KEY,
          ingredients: food_items_array.map(({ name }) => name).join(", "),
          number: 7,
          ranking: 1,
        },
      })
      .catch((err) => console.log(err, err.response.data, err.request));

    console.log({ suggested_recipes });

    let { data: recipe_options } = await axios
      .get(`https://api.spoonacular.com/recipes/informationBulk`, {
        params: {
          apiKey: process.env.SPOONACULAR_API_KEY,
          includeNutrition: true,
          ids: suggested_recipes.map((recipe) => recipe.id).join(", "),
        },
      })
      .catch((err) => console.log(err, error.response.data, err.request));
    recipe_options = suggested_recipes.map((suggested_recipe, i) => ({
      ...suggested_recipe,
      ...recipe_options[i],
    }));

    console.log("recipe_options: ", recipe_options);

    const recipe_options_in_snake_case = objectToSnake(recipe_options).map(
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

    console.log({ recipe_options_in_snake_case });
    await supabase
      .from("recipe_ids")
      .upsert(recipe_options_in_snake_case, { onConflict: "id" })
      .throwOnError();

    await AsyncStorage.setItem(
      "recipe_options",
      JSON.stringify(recipe_options_in_snake_case),
    );
    setIsLoading(false);

    // navigate to recipes screen to select options to keep
    // once selected, save the selected options to the database
    navigation.navigate("RecipeOptions");
  };

  return (
    <View style={styles.container}>
      <TouchableOpacity
        style={styles.buttonContainer}
        onPress={generate_recipes}
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
              <Text style={styles.gptTitle}>
                GPT Validation for Recipe {index + 1}:
              </Text>
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
