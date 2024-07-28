import React from "react";
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  Dimensions,
} from "react-native";
import RecipeCard from "../components/RecipeCard";
import { useNavigation } from "@react-navigation/native";
import { useAppStore } from "../stores/app-store";
import { useQuery } from "react-query";
import { fetchSavedRecipesByUser } from "../utils/supabase";

const screenWidth = Dimensions.get("window").width;
const screenHeight = Dimensions.get("window").height;

const SavedRecipes = () => {
  const navigation = useNavigation();
  const user_id = useAppStore((state) => state.user_id);
  const setUserId = useAppStore((state) => state.set_user_id); // Get the set_user_id function from the store

  const {
    data: savedRecipes,
    isLoading,
    error,
  } = useQuery(
    ["savedRecipes", user_id],
    async () => await fetchSavedRecipesByUser(user_id),
    {
      enabled: !!user_id, // Only run the query if user_id is not null
    },
  );

  const navigate_to_recipe_page = (recipe_id) => () => {
    navigation.navigate("RecipePage", { id: recipe_id });
    console.log("Navigating to recipe page with id: ", recipe_id);
  };

  if (user_id?.startsWith("guest")) {
    return (
      <View style={styles.container}>
        <Text style={styles.noRecipesText}>
          Please{" "}
          <TouchableOpacity
            onPress={() => {
              setUserId(null); // Nullify the user ID
            }}
          >
            <Text style={styles.loginText}>log in</Text>
          </TouchableOpacity>{" "}
          to view your saved recipes.
        </Text>
      </View>
    );
  }

  if (isLoading) {
    return (
      <View style={styles.container}>
        <Text style={styles.noRecipesText}>Loading...</Text>
      </View>
    );
  }

  if (error) {
    return (
      <View style={styles.container}>
        <Text style={styles.noRecipesText}>Error loading recipes.</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={{ marginBottom: screenHeight * 0.02 }}>
        <Text style={styles.text}>Saved Recipes</Text>
      </View>
      {savedRecipes && savedRecipes.length > 0 ? (
        <ScrollView contentContainerStyle={styles.scrollViewContent}>
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
    paddingTop: screenHeight * 0.07, // Responsive padding
    paddingBottom: screenHeight * 0.02, // Responsive padding
  },
  scrollViewContent: {
    flexGrow: 1,
    paddingHorizontal: screenWidth * 0.04, // Responsive padding
  },
  text: {
    color: "white",
    fontSize: screenWidth * 0.06, // Responsive font size
    fontWeight: "bold",
  },
  noRecipesText: {
    color: "white",
    fontSize: screenWidth * 0.045, // Responsive font size
    textAlign: "center",
    marginTop: screenHeight * 0.03, // Responsive margin
  },
  loginText: {
    color: "#38F096",
    textDecorationLine: "underline",
    fontWeight: "bold",
    fontSize: screenWidth * 0.04, // Responsive font size
  },
});

export default SavedRecipes;
