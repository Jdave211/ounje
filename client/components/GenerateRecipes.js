import React, { useState, useEffect } from "react";
import { View, StyleSheet, TouchableOpacity, Text, Alert } from "react-native";
import axios from "axios";
import { FOOD_ITEMS } from "../utils/constants";
import {
  GENERATE_RECIPE_LIST_FROM_INGREDIENTS_PROMPT,
  GENERATE_RECIPES_PROMPT,
  GENERATE_RECIPE_DETAILS_PROMPT_V2,
} from "../utils/prompts";
import { supabase, generate_and_store_image } from "../utils/supabase";
import CaseConvert, { objectToSnake } from "ts-case-convert";
import { useNavigation } from "@react-navigation/native";
import {
  openai,
  extract_json,
  format_generated_recipe,
  format_spoonacular_recipe,
} from "../utils/openai";
import { useAppStore, useTmpStore } from "../stores/app-store";
import { useRecipeOptionsStore } from "../stores/recipe-options-store";
import {
  find_recipes_by_ingredients,
  find_recipes_by_ingredients_and_store,
} from "../utils/spoonacular";
import { generate_image } from "../utils/stability";
import { map, zip } from "itertools";
import { nanoid } from "nanoid/non-secure";

export default function GenerateRecipes({ onLoading, onRecipesGenerated }) {
  const navigation = useNavigation();
  const [isLoading, setIsLoading] = useState(false);

  const userId = useAppStore((state) => state.user_id);
  const setRecipeOptions = useRecipeOptionsStore(
    (state) => state.setRecipeOptions
  );

  const selectedMealType = useRecipeOptionsStore(
    (state) => state.dish_types[0]
  );
  console.log({ selectedMealType });

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

      const recipe_list_response = [
        JSON.parse(recipe_list_response_text).recipes[0],
      ];

      // console.log({ recipe_list_response });

      const generate_recipe_details = async (recipe) => {
        const system_prompt = {
          role: "system",
          content: GENERATE_RECIPE_DETAILS_PROMPT_V2,
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

        // console.log({ recipe_details_response });
        const recipe_details_parsed_to_json = JSON.parse(
          recipe_details_response
        );
        console.log({ recipe_details_parsed_to_json });
        return recipe_details_parsed_to_json;
      };

      const recipe_details_bulk_request = Promise.allSettled(
        recipe_list_response.map(generate_recipe_details)
      );

      const generated_recipe_images_bulk_request = Promise.allSettled(
        recipe_list_response.map(({ title, description }) =>
          generate_and_store_image(
            "a delicious dish of a recipe descibed as " + description,
            "recipe_images",
            title.split(" ").join("_").toLowerCase() +
              "_" +
              nanoid().slice(0, 4) +
              ".jpeg"
          )
        )
      );

      const [
        recipe_details_bulk_response,
        // generated_recipe_images_bulk_response,
      ] = await Promise.all([
        recipe_details_bulk_request,
        // generated_recipe_images_bulk_request,
      ]);

      // console.log({ recipe_details_bulk_response });
      const generated_bulk_recipes = [];

      for (const recipe_async_res of recipe_details_bulk_response) {
        const recipe = recipe_async_res.value;

        recipe.image = "";
        recipe.image_type = "image/jpeg";
        // const image = image_async_res.value;
        // recipe.image_url = supabase.storage
        //   .from("recipe_images")
        //   .getPublicUrl(image.path).data.publicUrl;

        recipe.summary = recipe.description;

        format_generated_recipe(recipe);
        generated_bulk_recipes.push(recipe);
      }

      const { data: generated_recipes } = await supabase
        .from("recipe_ids")
        .insert(generated_bulk_recipes)
        .select()
        .throwOnError();

      return generated_recipes;
    } catch (error) {
      console.error("Error generating recipes with GPT:", error);
      return [];
    }
  };

  const generateRecipes = async () => {
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

        const { stored_suggested_recipes, new_suggested_recipes } =
          await find_recipes_by_ingredients(foodItems);

        // // Format spoonacular recipe details and generate gpt recipes
        // const new_formatted_recipes_request = Promise.all(
        //   new_suggested_recipes.map(format_spoonacular_recipe)
        // );

        // const [
        //   new_formatted_recipes,
        //   gpt_generated_recipes,
        // ] = await Promise.all([
        //   new_formatted_recipes_request,
        //   generateGPTRecipes(foodItems, stored_suggested_recipes),
        // ]);

        const new_formatted_recipes = new_suggested_recipes;

        const { data: new_stored_recipes } = await supabase
          .from("recipe_ids")
          .upsert(new_formatted_recipes, {
            onConflict: "spoonacular_id",
            // ignoreDuplicates: true, // note: duplicates will be missing from returned data in recipes_with_ids
          })
          .select()
          .throwOnError();

        const total_recipes = [
          ...stored_suggested_recipes,
          ...new_stored_recipes,
          // ...gpt_generated_recipes,
        ];

        setRecipeOptions(total_recipes); // Update the temporary state with the combined recipes
        console.log("All Recipes:", total_recipes);
      } catch (error) {
        console.error("Error generating recipes:", error);
        console.trace(error);
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
