import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  StyleSheet,
  Image,
  TouchableOpacity,
  Dimensions,
  ScrollView,
} from "react-native";
import { AntDesign, Feather, MaterialIcons } from "@expo/vector-icons";
import Toast from "react-native-toast-message";
import { supabase } from "../utils/supabase";
import Carousel from "react-native-reanimated-carousel";
import { entitle } from "../utils/helpers";
import harvestImage from "../assets/harvest.png";
import { Bar as ProgressBar } from "react-native-progress";
import RenderHtml from "react-native-render-html";
import { useWindowDimensions } from "react-native";
import { useNavigation } from "@react-navigation/native";
import { useAppStore } from "../stores/app-store";
import { useQuery } from "react-query";
import { fetchRecipeDetails } from "../utils/spoonacular";
import { fetchIsRecipeSavedByUser } from "../utils/supabase";
import { usePercentageOfIngredientsOwned } from "../hooks/usePercentageOfIngredientsOwned";

const RecipePage = ({ route }) => {
  const { width: WIDTH } = useWindowDimensions();
  const { id: recipe_id } = route.params;
  const navigation = useNavigation();
  const PAGE_WIDTH = Dimensions.get("window").width;
  const [isRecipeSaved, setIsRecipeSaved] = useState(false);
  const user_id = useAppStore((state) => state.user_id);

  const { data: recipeDetails } = useQuery(
    ["recipeDetails", recipe_id],
    async () => await fetchRecipeDetails(recipe_id)
  );
  const { data: isAlreadySaved } = useQuery(
    ["isRecipeSaved", user_id],
    async () => await fetchIsRecipeSavedByUser(user_id, recipe_id),
    {
      onSuccess: () => setIsRecipeSaved(isAlreadySaved),
    }
  );
  const percentage_of_ingredients_owned =
    usePercentageOfIngredientsOwned(recipeDetails);

  const handleSave = async () => {
    const localIsRecipeSaved = !isRecipeSaved;
    setIsRecipeSaved(localIsRecipeSaved);

    if (localIsRecipeSaved) {
      await supabase
        .from("saved_recipes")
        .insert([{ user_id, recipe_id: recipeDetails.id }])
        .throwOnError();
      Toast.show({
        type: "success",
        text1: "Recipe Saved",
        text2: `${recipeDetails.title} has been saved to your collection.`,
      });
    } else {
      await supabase
        .from("saved_recipes")
        .delete()
        .eq("user_id", user_id)
        .eq("recipe_id", recipeDetails.id)
        .throwOnError();
      Toast.show({
        type: "success",
        text1: "Recipe Unsaved",
        text2: `${recipeDetails.title} has been removed from your collection.`,
      });
    }
  };

  const onReturnToPreviousPage = () => {
    const currentNavigationState = navigation.getState();
    console.log("Current Navigation State:", currentNavigationState);

    // Navigate back to the previous screen
    if (navigation.canGoBack()) {
      navigation.goBack();
    } else {
      console.warn("STFU"); // omo this guy was really warning the code
    }
  };

  const truncateDescription = (description = "") => {
    const index = description.indexOf("spoonacular");
    if (index !== -1) {
      return description.substring(0, index) + "...";
    }
    return description.length > 200
      ? description.substring(0, 200) + "..."
      : description;
  };

  return (
    recipeDetails && (
      <ScrollView
        style={styles.container}
        stickyHeaderIndices={[0]}
        showsVerticalScrollIndicator={false}
      >
        <View style={styles.header}>
          <TouchableOpacity
            style={styles.backButton}
            onPress={onReturnToPreviousPage}
          >
            <AntDesign name="arrowleft" size={24} color={"white"} />
          </TouchableOpacity>
          <TouchableOpacity style={styles.saveButton} onPress={handleSave}>
            {isRecipeSaved ? (
              <MaterialIcons name="bookmark-add" size={24} color="green" />
            ) : (
              <MaterialIcons name="bookmark-border" size={24} color="white" />
            )}
          </TouchableOpacity>
        </View>

        <View>
          <Carousel
            loop
            width={PAGE_WIDTH}
            height={PAGE_WIDTH / 2}
            data={[0]}
            scrollAnimationDuration={1000}
            renderItem={() => (
              <View style={styles.carouselItem}>
                <Image
                  style={styles.carouselImage}
                  source={{ uri: recipeDetails.image }}
                />
              </View>
            )}
          />
        </View>

        <View style={styles.content}>
          <Text style={styles.title}>{recipeDetails.title}</Text>
          <View style={styles.details}>
            <View style={styles.detailsRow}>
              <Feather name="clock" size={20} color="green" />
              <Text style={styles.text}>
                {recipeDetails.ready_in_minutes} mins
              </Text>
            </View>
            <View style={styles.progressContainer}>
              <Text style={styles.text}>
                {percentage_of_ingredients_owned.toFixed(0)}% of Ingredients
              </Text>
              <View style={styles.progressBar}>
                <ProgressBar
                  progress={percentage_of_ingredients_owned / 100}
                  width={100}
                  color="green"
                />
                <Image source={harvestImage} style={styles.harvestImage} />
              </View>
            </View>
          </View>

          <Text style={styles.subheading}>Description</Text>
          <Text style={styles.text} numberOfLines={5}>
            {recipeDetails.summary}
          </Text>
          <RenderHtml
            baseStyle={styles.text}
            contentWidth={WIDTH}
            source={{
              html: `<div>${recipeDetails.summary}</div>`,
            }}
          />
          <View style={styles.fullIngredients}>
            <Text style={styles.subheading}>Ingredients</Text>
            {recipeDetails.extended_ingredients.map((ingredient, i) => (
              <View key={i} style={styles.ingredient}>
                <Image
                  style={styles.ingredientImage}
                  source={{
                    uri: `https://img.spoonacular.com/ingredients_100x100/${ingredient.image}`,
                  }}
                />
                <View style={styles.ingredientTextContainer}>
                  <Text style={styles.ingredientText}>
                    {entitle(ingredient.name)}
                  </Text>
                  <Text style={styles.ingredientAmount}>
                    {ingredient.amount} {ingredient.unit}
                  </Text>
                </View>
              </View>
            ))}
          </View>
          <View style={styles.fullInstructions}>
            <Text style={styles.subheading}>Instructions</Text>
            {recipeDetails.analyzed_instructions &&
            recipeDetails.analyzed_instructions[0] &&
            recipeDetails.analyzed_instructions[0].steps ? (
              recipeDetails.analyzed_instructions[0].steps.map(
                ({ step, number }) => (
                  <View key={number} style={styles.instruction}>
                    <Text style={styles.text}>{number}.</Text>
                    <Text style={styles.text}>{step}</Text>
                  </View>
                )
              )
            ) : (
              <Text style={styles.text}>
                No detailed instructions available for this recipe.
              </Text>
            )}
          </View>
        </View>
      </ScrollView>
    )
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#121212",
    paddingTop: 45,
    paddingHorizontal: 10,
  },
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    height: 50,
  },
  backButton: {
    backgroundColor: "#2e2d2d",
    borderRadius: 100,
    padding: 8,
    width: 50,
    justifyContent: "center",
    alignItems: "center",
  },
  saveButton: {
    //backgroundColor: "#2e2d2d",
    borderRadius: 100,
    padding: 8,
    width: 50,
    justifyContent: "center",
    alignItems: "center",
    position: "absolute",
    right: 10,
  },
  saved: {
    backgroundColor: "#2e2d2d", // Style for the saved state
  },
  notSaved: {
    backgroundColor: "green", // Style for the not saved state
  },
  carouselItem: {
    flex: 1,
    justifyContent: "center",
  },
  carouselImage: {
    width: "100%",
    height: 200,
    borderRadius: 10,
  },
  content: {
    padding: 10,
  },
  title: {
    fontSize: 20,
    fontWeight: "bold",
    color: "white",
    marginBottom: 10,
  },
  details: {
    flexDirection: "column",
    justifyContent: "space-between",
    alignItems: "left",
    marginBottom: 10,
  },
  detailsRow: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 5,
  },
  progressContainer: {
    flexDirection: "row",
    alignItems: "center",
  },
  progressBar: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    width: 100,
    marginLeft: 10,
  },
  harvestImage: {
    resizeMode: "cover",
    width: 24,
    height: 24,
    marginLeft: 10,
  },
  subheading: {
    fontSize: 20,
    fontWeight: "bold",
    marginTop: 20,
    marginBottom: 10,
    color: "white",
  },
  text: {
    fontSize: 16,
    color: "white",
  },
  fullIngredients: {
    marginTop: 10,
    marginBottom: 5,
  },
  ingredient: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingVertical: 10,
  },
  ingredientImage: {
    width: 30,
    height: 30,
    borderRadius: 10,
    marginRight: 10,
  },
  ingredientTextContainer: {
    flex: 1,
    flexDirection: "column",
    alignItems: "flex-start",
  },
  ingredientText: {
    fontSize: 16,
    color: "white",
  },
  ingredientAmount: {
    fontSize: 14,
    color: "gray",
  },
  fullInstructions: {
    marginTop: 5,
    marginBottom: 45,
  },
  instruction: {
    flexDirection: "row",
    alignItems: "flex-start",
    paddingVertical: 8,
    marginBottom: 7,
  },
});

export default RecipePage;
