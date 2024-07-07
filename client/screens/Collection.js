import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  TouchableOpacity,
  ScrollView,
  TouchableWithoutFeedback,
} from "react-native";
import RecipeCard from "../components/RecipeCard";
import { supabase } from "../utils/supabase";
import { useNavigation } from "@react-navigation/native";
import { useAppStore } from "../stores/app-store";
import { useQuery } from "react-query";
import { fetchSavedRecipesByUser } from "../utils/supabase";

const SavedRecipes = () => {
  const navigation = useNavigation();

  const user_id = useAppStore((state) => state.user_id);
  const { data: savedRecipes } = useQuery(
    ["savedRecipes", user_id],
    async () => await fetchSavedRecipesByUser(user_id)
  );

  const navigate_to_recipe_page = (recipe_id) => () => {
    navigation.navigate("RecipePage", { id: recipe_id });
    console.log("Navigating to recipe page with id: ", recipe_id);
  };

  return (
    <View style={styles.container}>
      <View style={{ marginBottom: 10 }}>
        <Text style={styles.text}>Saved Recipes</Text>
      </View>
      {savedRecipes && savedRecipes.length > 0 ? (
        <ScrollView>
          {savedRecipes.map((recipe_id, i) => (
            <TouchableOpacity
              key={i}
              onPress={navigate_to_recipe_page(recipe_id)}
            >
              <RecipeCard id={recipe_id} showBookmark={true} />
            </TouchableOpacity>
          ))}
        </ScrollView>
      ) : (
        <Text style={styles.noRecipesText}>No recipes have been saved.</Text>
      )}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "#121212",
    paddingTop: 55,
    paddingBottom: 11,
  },
  text: {
    color: "white",
    fontSize: 24,
    fontWeight: "bold",
  },
  noRecipesText: {
    color: "white",
    fontSize: 18,
    textAlign: "center",
    marginTop: 20,
  },
});

export default SavedRecipes;
