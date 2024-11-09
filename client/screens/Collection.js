import React, { useEffect, useState } from "react";
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
import { useQuery, useQueryClient } from "react-query";
import { fetchSavedRecipesByUser, unsaveRecipe } from "../utils/supabase";
import DiscoverRecipes from "../components/DiscoverRecipes";

const screenWidth = Dimensions.get("window").width;
const screenHeight = Dimensions.get("window").height;

const SavedRecipes = () => {
  const [selectedTab, setSelectedTab] = useState("SavedRecipes"); // State to track the selected tab (Saved Recipes or Discover)
  const navigation = useNavigation();
  const user_id = useAppStore((state) => state.user_id); // Get the user ID from global state
  const setUserId = useAppStore((state) => state.set_user_id); // Function to update the user ID in global state
  const queryClient = useQueryClient();

  // Query to fetch saved recipes for the current user
  const {
    data: savedRecipes,
    isLoading,
    error,
  } = useQuery(
    ["savedRecipes", user_id], // Query key
    async () => await fetchSavedRecipesByUser(user_id), // Fetch function
    {
      enabled: !!user_id, // Only run the query if user_id is defined
    }
  );

  // Effect to refetch saved recipes when the screen is focused
  useEffect(() => {
    const unsubscribe = navigation.addListener("focus", () => {
      // Refetch saved recipes when the screen is focused
      queryClient.invalidateQueries(["savedRecipes", user_id]); // Invalidate the query to trigger a refetch
      console.log("================ unsaved recipe: ", user_id);
    });

    return unsubscribe; // Clean up the event listener
  }, [navigation, queryClient, user_id]); // Add dependencies to the effect

  const handleUnsaveRecipe = async (recipe_id) => {
    try {
      await unsaveRecipe(user_id, recipe_id); // Call your unsave function
      // Invalidate the query to refresh the saved recipes list
      queryClient.invalidateQueries(["savedRecipes", user_id]);
    } catch (error) {
      console.error("Error unsaving recipe:", error);
    }
  };

  // Function to navigate to the recipe page
  const navigate_to_recipe_page = (recipe_id) => () => {
    navigation.navigate("RecipePage", { id: recipe_id }); // Navigate to the RecipePage with the selected recipe ID
    console.log("Navigating to recipe page with id: ", recipe_id);
  };

  // Render logic for guest users
  if (user_id?.startsWith("guest")) {
    return (
      <View style={styles.container}>
        <Text style={styles.noRecipesText}>
          Please{" "}
          <TouchableOpacity
            onPress={() => {
              setUserId(null);
            }}
          >
            <Text style={styles.loginText}>log in</Text>
          </TouchableOpacity>{" "}
          to view your saved recipes.
        </Text>
      </View>
    );
  }

  // Render logic for loading state
  if (isLoading) {
    return (
      <View style={styles.container}>
        <Text style={styles.noRecipesText}>Loading...</Text>
      </View>
    );
  }

  // Render logic for error state
  if (error) {
    return (
      <View style={styles.container}>
        <Text style={styles.noRecipesText}>Error loading recipes.</Text>
      </View>
    );
  }

  // Main render for the Saved Recipes component
  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.headerText}>Collection</Text>
        <Text style={styles.headerSubtext}>Your favorite recipes & more</Text>
      </View>

      <View style={styles.segmentedControl}>
        <TouchableOpacity
          style={[
            styles.segmentButton,
            selectedTab === "SavedRecipes" && styles.segmentButtonSelected,
          ]}
          onPress={() => setSelectedTab("SavedRecipes")}
        >
          <Text
            style={[
              styles.segmentButtonText,
              selectedTab === "SavedRecipes" &&
                styles.segmentButtonTextSelected,
            ]}
          >
            Saved Recipes
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[
            styles.segmentButton,
            selectedTab === "Discover" && styles.segmentButtonSelected,
          ]}
          onPress={() => setSelectedTab("Discover")}
        >
          <Text
            style={[
              styles.segmentButtonText,
              selectedTab === "Discover" && styles.segmentButtonTextSelected,
            ]}
          >
            Discover
          </Text>
        </TouchableOpacity>
      </View>
      <ScrollView
        showsVerticalScrollIndicator={false}
        contentContainerStyle={styles.scrollViewContent}
      >
        {selectedTab === "SavedRecipes" && (
          <View style={styles.content}>
            {savedRecipes && savedRecipes.length > 0 ? (
              savedRecipes.map((recipe_id, i) => (
                <TouchableOpacity
                  key={i}
                  onPress={navigate_to_recipe_page(recipe_id)}
                  style={styles.recipeCard}
                >
                  <RecipeCard
                    id={recipe_id}
                    showBookmark={true}
                    onUnsave={() => handleUnsaveRecipe(recipe_id)}
                  />
                </TouchableOpacity>
              ))
            ) : (
              <Text style={styles.noRecipesText}>
                No recipes have been saved.
              </Text>
            )}

          </View>
        )}
        </ScrollView>

        {selectedTab === "Discover" && (
          <View>
            {/* // <Text style={styles.discoverCardTitle}>Discover Recipes</Text> */}
            {/* <Text style={styles.warning}>
              Save more recipes to discover ones that meet your taste!
            </Text> */}
            <DiscoverRecipes />
        </View>
        )}
      
    </View>
  );
};

const styles = StyleSheet.create({
  scrollViewContent: {
    flexGrow: 1,
    backgroundColor: "#121212",
  },
  container: {
    padding: Dimensions.get("window").width * 0.03,
    backgroundColor: "#121212",
    flexGrow: 1,
  },
  header: {
    justifyContent: "flex-start",
    alignItems: "flex-start",
    marginBottom: Dimensions.get("window").height * 0.05,
    marginTop: Dimensions.get("window").height * 0.1,
    marginLeft: Dimensions.get("window").width * 0.03,
  },
  headerText: {
    color: "#fff",
    fontSize: 25,
    fontWeight: "bold",
  },
  headerSubtext: {
    color: "gray",
    fontSize: screenWidth * 0.04,
    marginTop: 5,
  },
  segmentedControl: {
    flexDirection: "row",
    alignSelf: "stretch",
    marginBottom: 20,
    borderBottomWidth: 1,
    borderBottomColor: "#282C35",
  },
  segmentButton: {
    flex: 1,
    paddingVertical: 10,
    alignItems: "center",
  },
  segmentButtonSelected: {
    borderBottomWidth: 2,
    borderBottomColor: "gray",
  },
  segmentButtonText: {
    color: "gray",
    fontSize: 16,
  },
  segmentButtonTextSelected: {
    color: "white",
    fontWeight: "bold",
  },
  content: {
    flex: 1,
    justifyContent: "center",
    width: "100%",
    paddingBottom: screenHeight * 0.28,
  },
  recipeCard: {
    marginBottom: screenHeight * 0.02,
  },
  noRecipesText: {
    color: "white",
    fontSize: screenWidth * 0.045,
    textAlign: "center",
    marginTop: screenHeight * 0.02,
  },
  discoverCard: {
    backgroundColor: "#1f1f1f",
    borderRadius: 10,
    padding: 20,
    marginBottom: 20,
  },
  discoverCardTitle: {
    color: "#fff",
    fontSize: screenWidth * 0.045, // Responsive font size
    fontWeight: "bold",
    marginBottom: 10,
  },
  warning: {
    color: "gray",
    fontSize: screenWidth * 0.04,
  },
  loginText: {
    color: "#38F096",
    textDecorationLine: "underline",
    fontWeight: "bold",
    fontSize: screenWidth * 0.04,
  },
});

export default SavedRecipes;
