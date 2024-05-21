import React, { useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  TouchableOpacity,
  ScrollView,
  TouchableWithoutFeedback,
} from "react-native";
import RecipeCard from "@components/RecipeCard";

const SavedRecipes = () => {
  const store_selected_recipes = async (selected_recipes) => {
    const recipe_image_bucket = "recipe_images";

    const recipe_image_gen_data = selected_recipes.map((recipe) => ({
      prompt:
        "a zoomed out image showing the full dish of " + recipe.image_prompt,
      storage_path: `${current_run.id}/${recipe.name}.jpeg`,
    }));

    // generate and store images for each recipe
    // shoot and forget approach
    // no need to wait for the images to be generated or stored
    // we just let them run while we continue with the rest of the process
    // the urls to the image can be calculated from the storage path
    // so we can pass that into the app and it can fetch the images as needed
    await Promise.allSettled(
      selected_recipes.map(async (recipe) => {
        let recipe_image = await generate_image(
          "a zoomed out image showing the full dish of " + recipe.image_prompt,
        );

        let storage_path = `${current_run.id}/${recipe.name}.jpeg`;
        let image_storage_response = await store_image(
          recipe_image_bucket,
          storage_path,
          recipe_image,
        );

        return image_storage_response;
      }),
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

  return (
    <View style={styles.container}>
      <Text style={styles.text}>Generated Recipe Options</Text>
      <RecipeCard />
    </View>
  );
};

const styles = {
  container: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "black",
  },
  text: {
    color: "white",
    fontSize: 20,
  },
};

export default SavedRecipes;