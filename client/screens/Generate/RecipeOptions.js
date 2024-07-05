import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  ScrollView,
} from "react-native";
import RecipeCard from "@components/RecipeCard";
import { supabase } from "../../utils/supabase";
import { useNavigation } from "@react-navigation/native";
import { AntDesign } from "@expo/vector-icons";
import { useAppStore, useTmpStore } from "@stores/app-store";
import { useRecipeOptionsStore } from "../../stores/recipe-options-store";

const RecipeOptions = () => {
  const navigation = useNavigation();

  const user_id = useAppStore((state) => state.user_id);
  const recipeOptions = useRecipeOptionsStore((state) => state.recipe_options);

  const store_selected_recipes = async (selected_recipes) => {
    const recipe_image_bucket = "recipe_images";

    await Promise.allSettled(
      selected_recipes.map(async (recipe) => {
        let recipe_image = await generate_image(
          "a zoomed out image showing the full dish of " + recipe.image_prompt
        );

        let storage_path = `${current_run.id}/${recipe.name}.jpeg`;
        let image_storage_response = await store_image(
          recipe_image_bucket,
          storage_path,
          recipe_image
        );

        return image_storage_response;
      })
    );

    const recipe_records = selected_recipes.map((recipe) => {
      delete recipe.image_prompt;
      let storage_path = `${current_run.id}/${recipe.name}.jpeg`;

      let {
        data: { publicUrl: image_url },
      } = supabase.storage.from(recipe_image_bucket).getPublicUrl(storage_path);

      recipe["image_url"] = image_url;

      return recipe;
    });

    console.log("recipe_records: ", recipe_records);

    return await supabase
      .from("recipes")
      .upsert(recipe_records, { onConflict: ["name"] })
      .throwOnError();
  };

  const navigate_to_saved_recipes = () => {
    navigation.navigate("SavedRecipes");
  };

  console.log({ recipeOptions });

  const navigate_to_recipe_page = (recipe_id) => () => {
    navigation.navigate("RecipePage", { id: recipe_id });
  };

  return (
    <View style={styles.container}>
      <TouchableOpacity
        style={styles.backButton}
        onPress={() => navigation.goBack()}
      >
        <AntDesign name="arrowleft" size={24} color="white" />
      </TouchableOpacity>
      <View style={styles.content}>
        <Text style={styles.text}>Generated Recipes</Text>
        <ScrollView style={styles.recipes}>
          {recipeOptions.map((recipeOption, index) => (
            <TouchableOpacity
              key={index}
              onPress={navigate_to_recipe_page(recipeOption.id)}
            >
              <RecipeCard
                key={index}
                id={recipeOption.id}
                showBookmark={true}
                title={recipeOption.title || recipeOption.Recipe}
                summary={recipeOption.summary || recipeOption.Summary}
                imageUrl={recipeOption.image_url || recipeOption.image}
                readyInMinutes={
                  recipeOption.ready_in_minutes || recipeOption.CookTime
                }
                servings={recipeOption.servings || recipeOption.Servings}
                calories={recipeOption.calories || recipeOption.Calories}
              />
            </TouchableOpacity>
          ))}
        </ScrollView>
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#121212",
    padding: 15,
  },
  backButton: {
    position: "absolute",
    top: 67,
    left: 15,
    backgroundColor: "#2e2d2d",
    borderRadius: 100,
    padding: 8,
    width: 50,
    justifyContent: "center",
    alignItems: "center",
    zIndex: 1,
  },
  content: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    paddingTop: 20,
    marginTop: 20,
    marginBottom: 11,
  },
  text: {
    color: "white",
    fontSize: 20,
    fontWeight: "bold",
    position: "absolute",
    top: 40,
  },
  recipes: {
    marginTop: 60, // Adjust this value to position the list correctly below the title
    width: "105%",
    height: "100%",
  },
});

export default RecipeOptions;
