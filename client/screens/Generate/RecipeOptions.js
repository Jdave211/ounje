import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  ScrollView,
  Dimensions,
} from "react-native";
import RecipeCard from "../../components/RecipeCard";
import { supabase } from "../../utils/supabase";
import { useNavigation } from "@react-navigation/native";
import { AntDesign } from "@expo/vector-icons";
import { useAppStore } from "../../stores/app-store";
import { useRecipeOptionsStore } from "../../stores/recipe-options-store";
import { useInventoryHooks } from "../../hooks/usePercentageOfIngredientsOwned";

const screenWidth = Dimensions.get("window").width;
const screenHeight = Dimensions.get("window").height;

const RecipeOptions = () => {
  const navigation = useNavigation();

  const user_id = useAppStore((state) => state.user_id);
  const recipeOptions = useRecipeOptionsStore((state) => state.recipe_options);
  const dish_types = useRecipeOptionsStore((state) => state.dish_types);
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

          const { owned_items: a_owned_items } = separateIngredients(a);
          a_score += a_owned_items.length / a.extended_ingredients.length;

          const { owned_items: b_owned_items } = separateIngredients(b);
          b_score += b_owned_items.length / b.extended_ingredients.length;

          return b_score - a_score;
        })
        .slice(0, 25),
    [recipeOptions, dish_types_set]
  );

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
      <View style={styles.header}>
        <Text style={styles.headerText}>Generated Recipes</Text>
        <Text style={styles.subHeaderText}>Here are your recipes</Text>
      </View>
      <View style={styles.content}>
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
    padding: screenWidth * 0.04, // Responsive padding
  },
  backButton: {
    position: "absolute",
    top: screenHeight * 0.08, // Responsive position
    left: screenWidth * 0.04, // Responsive position
    backgroundColor: "#2e2d2d",
    borderRadius: 100,
    padding: screenWidth * 0.02, // Responsive padding
    width: screenWidth * 0.12, // Responsive width
    justifyContent: "center",
    alignItems: "center",
    zIndex: 1,
  },
  header: {
    justifyContent: "flex-end",
    alignItems: "flex-end",
    marginBottom: Dimensions.get("window").height * 0.01,
    marginTop: Dimensions.get("window").height * 0.068,
    marginLeft: Dimensions.get("window").width * 0.03,
  },
  headerText: {
    color: "#fff",
    fontSize: 25,
    fontWeight: "bold",
  },
  subHeaderText: {
    color: "gray",
    fontSize: screenWidth * 0.04,
  },
  content: {
    flex: 1,
    marginTop: screenHeight * 0.01, // Responsive margin
  },
  recipes: {
    marginTop: screenHeight * 0.04, // Responsive margin
    width: "100%",
    height: "100%",
  },
});

export default RecipeOptions;
