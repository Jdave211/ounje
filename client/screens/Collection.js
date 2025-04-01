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
import DiscoverRecipes from "./DiscoverRecipe/DiscoverRecipes";

const SavedRecipes = () => {
  const [dimensions, setDimensions] = useState({
    width: Dimensions.get("window").width,
    height: Dimensions.get("window").height,
  });
  const [selectedTab, setSelectedTab] = useState("SavedRecipes");
  // Create styles using current dimensions
  const styles = React.useMemo(() => getStyles(dimensions), [dimensions]);
  const navigation = useNavigation();
  const user_id = useAppStore((state) => state.user_id);
  const setUserId = useAppStore((state) => state.set_user_id);
  const queryClient = useQueryClient();

  // Handle dimension changes
  useEffect(() => {
    const subscription = Dimensions.addEventListener("change", ({ window }) => {
      setDimensions({
        width: window.width,
        height: window.height,
      });
    });

    return () => {
      subscription.remove();
      // Cleanup query cache on unmount
      queryClient.removeQueries(["savedRecipes", user_id]);
    };
  }, [queryClient, user_id]);

  // Query with error handling and retry logic
  const {
    data: savedRecipes,
    isLoading,
    error,
  } = useQuery(
    ["savedRecipes", user_id],
    async () => {
      try {
        return await fetchSavedRecipesByUser(user_id);
      } catch (error) {
        console.error("Error fetching saved recipes:", error);
        throw new Error("Failed to fetch saved recipes");
      }
    },
    {
      enabled: !!user_id && !user_id.startsWith("guest"),
      retry: 2,
      retryDelay: (attemptIndex) => Math.min(1000 * 2 ** attemptIndex, 10000),
      staleTime: 300000, // 5 minutes
      cacheTime: 3600000, // 1 hour
    }
  );

  // Memoized focus handler
  const handleFocus = React.useCallback(() => {
    if (user_id) {
      queryClient.invalidateQueries(["savedRecipes", user_id]);
    }
  }, [queryClient, user_id]);

  useEffect(() => {
    const unsubscribe = navigation.addListener("focus", handleFocus);
    return unsubscribe;
  }, [navigation, handleFocus]);

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
        {selectedTab === "SavedRecipes" ? (
          <View style={styles.content}>
            {savedRecipes && savedRecipes.length > 0 ? (
              savedRecipes.map((recipe_id, i) => (
                (() => {
                  try {
                    return (
                      <TouchableOpacity
                        key={recipe_id}
                        onPress={navigate_to_recipe_page(recipe_id)}
                        style={styles.recipeCard}
                      >
                        <RecipeCard
                          id={recipe_id}
                          showBookmark={true}
                          onUnsave={() => handleUnsaveRecipe(recipe_id)}
                        />
                      </TouchableOpacity>
                    );
                  } catch (error) {
                    console.error(`Error rendering recipe card ${recipe_id}:`, error);
                    return null;
                  }
                })()
              ))
            ) : (
              <Text style={styles.noRecipesText}>
                No recipes have been saved.
              </Text>
            )}
          </View>
        ) : (
          <View style={styles.content}>
            {(() => {
              try {
                return <DiscoverRecipes />;
              } catch (error) {
                console.error('Error rendering DiscoverRecipes:', error);
                return (
                  <Text style={styles.noRecipesText}>
                    Unable to load discover section. Please try again later.
                  </Text>
                );
              }
            })()}
          </View>
        )}
      </ScrollView>
      
    </View>
  );
};

const getStyles = (dimensions) => StyleSheet.create({
  scrollViewContent: {
    flexGrow: 1,
    backgroundColor: "#121212",
  },
  container: {
    padding: Math.min(dimensions.width * 0.03, 30),
    backgroundColor: "#121212",
    flexGrow: 1,
  },
  header: {
    justifyContent: "flex-start",
    alignItems: "flex-start",
    marginBottom: Math.min(dimensions.height * 0.05, 40),
    marginTop: Math.min(dimensions.height * 0.08, 60),
    marginLeft: Math.min(dimensions.width * 0.03, 30),
  },
  headerText: {
    color: "#fff",
    fontSize: Math.min(dimensions.width * 0.06, 32),
    fontWeight: "bold",
  },
  headerSubtext: {
    color: "gray",
    fontSize: Math.min(dimensions.width * 0.04, 18),
    marginTop: 5,
  },
  segmentedControl: {
    flexDirection: "row",
    alignSelf: "stretch",
    marginBottom: Math.min(dimensions.height * 0.03, 24),
    borderBottomWidth: 1,
    borderBottomColor: "#282C35",
    paddingHorizontal: Math.min(dimensions.width * 0.02, 20),
  },
  segmentButton: {
    flex: 1,
    paddingVertical: Math.min(dimensions.height * 0.015, 12),
    alignItems: "center",
  },
  segmentButtonSelected: {
    borderBottomWidth: 2,
    borderBottomColor: "gray",
  },
  segmentButtonText: {
    color: "gray",
    fontSize: Math.min(dimensions.width * 0.04, 18),
  },
  segmentButtonTextSelected: {
    color: "white",
    fontWeight: "bold",
  },
  content: {
    flex: 1,
    justifyContent: "center",
    width: "100%",
    paddingBottom: Math.min(dimensions.height * 0.2, 120),
    paddingHorizontal: Math.min(dimensions.width * 0.02, 20),
  },
  recipeCard: {
    marginBottom: Math.min(dimensions.height * 0.02, 16),
    maxWidth: Math.min(dimensions.width, 600),
    alignSelf: "center",
    width: "100%",
  },
  noRecipesText: {
    color: "white",
    fontSize: Math.min(dimensions.width * 0.045, 20),
    textAlign: "center",
    marginTop: Math.min(dimensions.height * 0.02, 16),
  },
  loginText: {
    color: "#38F096",
    textDecorationLine: "underline",
    fontWeight: "bold",
    fontSize: Math.min(dimensions.width * 0.04, 18),
  },
});

export default SavedRecipes;
