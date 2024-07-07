import React, { useState, useEffect, useMemo } from "react";
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
import { useInventoryHooks } from "../../hooks/usePercentageOfIngredientsOwned";

const RecipeOptions = () => {
  const navigation = useNavigation();

  const user_id = useAppStore((state) => state.user_id);
  const recipeOptions = useRecipeOptionsStore((state) => state.recipe_options);
  const dish_types = useRecipeOptionsStore((state) => state.dish_types);
  console.log({ dish_types });
  const dish_types_set = useMemo(
    () => new Set(dish_types.map((t) => t.toLowerCase())),
    [dish_types]
  );

  const { separateIngredients } = useInventoryHooks();
  const sorted_recipe_options = useMemo(
    () =>
      recipeOptions
        .slice()
        .sort((a, b) => {
          let a_score = JSON.parse(a.dish_types).reduce(
            (acc, dish_type) =>
              acc + dish_types_set.has(dish_type.toLowerCase()),
            0
          );
          let b_score = JSON.parse(b.dish_types).reduce(
            (acc, dish_type) =>
              acc + dish_types_set.has(dish_type.toLowerCase()),
            0
          );

          const { owned_items: a_owned_items, missing_Items: a_missing_items } =
            separateIngredients(a);
          a_score += a_owned_items.length / a.extended_ingredients.length;

          const { owned_items: b_owned_items, missing_Items: b_missing_items } =
            separateIngredients(b);
          b_score += b_owned_items.length / b.extended_ingredients.length;

          return b_score - a_score;
        })
        .slice(0, 25),
    [recipeOptions, dish_types_set]
  );

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
        {/* <Text style={{ color: "white", fontSize: 15, marginBottom: 10 }}>
          Displaying {sorted_recipe_options.length} recipes
        </Text> */}
        <Text style={styles.text}>Generated Recipes</Text>

        <ScrollView style={styles.recipes}>
          {sorted_recipe_options.map((recipeOption, index) => (
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
