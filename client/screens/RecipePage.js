// RecipePage.js

import React, { useState, useMemo } from "react";
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
import {
  useInventoryHooks,
  usePercentageOfIngredientsOwned,
} from "../hooks/usePercentageOfIngredientsOwned";
import IngredientCard from "../components/IngredientCard";

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
    ["isRecipeSaved", user_id, recipe_id],
    async () => await fetchIsRecipeSavedByUser(user_id, recipe_id),
    {
      onSuccess: () => setIsRecipeSaved(isAlreadySaved),
    }
  );

  // State variables for owned and missing items
  const { separateIngredients } = useInventoryHooks();
  const initialIngredients = useMemo(
    () => separateIngredients(recipeDetails),
    [recipeDetails]
  );
  const [ownedItems, setOwnedItems] = useState(initialIngredients.owned_items);
  const [missingItems, setMissingItems] = useState(initialIngredients.missing_items);

  // Recalculate the percentage whenever ownedItems or total ingredients change
  const totalIngredients = recipeDetails?.extended_ingredients?.length || 0;
  const percentage_of_ingredients_owned =
    totalIngredients > 0 ? (ownedItems.length / totalIngredients) * 100 : 0;

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
    if (navigation.canGoBack()) {
      navigation.goBack();
    } else {
      console.warn("No previous page available");
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

  // Function to add ingredient to inventory
  const addIngredientToInventory = (ingredient) => {
    const inventory = useAppStore.getState().inventory;
    const newFoodItem = {
      // Structure this object according to your inventory schema
      name: ingredient.name,
      quantity: ingredient.amount,
      unit: ingredient.measures?.us.unit_short || ingredient.unit,
      image: ingredient.image,
      // Add any other necessary fields
    };

    // Add the new food item to the inventory
    inventory.addFoodItem(newFoodItem);

    // Update the owned and missing items state
    setOwnedItems((prevOwnedItems) => [...prevOwnedItems, ingredient]);
    setMissingItems((prevMissingItems) =>
      prevMissingItems.filter((item) => item.id !== ingredient.id)
    );

    Toast.show({
      type: "success",
      text1: "Ingredient Added",
      text2: `${ingredient.name} has been added to your inventory.`,
    });
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
              <Feather name="clock" size={20} color="silver" />
              <Text style={styles.text}>
                {"  "}
                {recipeDetails.ready_in_minutes} mins
              </Text>
            </View>
            <View style={styles.progressContainer}>
              <Text style={styles.text}>
                {ownedItems?.length} / {totalIngredients} Ingredients
              </Text>
              <View style={styles.progressBar}>
                <ProgressBar
                  progress={percentage_of_ingredients_owned / 100}
                  width={100}
                  color="#393E46"
                />
                <Image source={harvestImage} style={styles.harvestImage} />
              </View>
            </View>
          </View>

          <Text style={styles.subheading}>Description</Text>
          {recipeDetails.description ? (
            <Text style={styles.text}>{recipeDetails.description}</Text>
          ) : (
            <RenderHtml
              baseStyle={styles.text}
              contentWidth={WIDTH}
              source={{
                html: truncateDescription(recipeDetails.summary),
              }}
            />
          )}
          <View style={styles.fullIngredients}>
            <Text style={styles.subheading}>Owned Ingredients</Text>
            <ScrollView
              horizontal={true}
              showsHorizontalScrollIndicator={false}
            >
              <View style={styles.horizontalScroll}>
                {ownedItems.map((ingredient, i) => (
                  <View key={i} style={styles.ingredientCardWrapper}>
                    <IngredientCard
                      key={ingredient.id || i}
                      name={ingredient.name}
                      image={`https://spoonacular.com/cdn/ingredients_100x100/${ingredient.image}`}
                      amount={ingredient.amount}
                      unit={ingredient.measures?.us.unit_short}
                    />
                  </View>
                ))}
              </View>
            </ScrollView>

            <Text style={styles.subheading}>Missing Ingredients</Text>
            <ScrollView
              horizontal={true}
              showsHorizontalScrollIndicator={false}
            >
              <View style={styles.horizontalScroll}>
                {missingItems.map((ingredient, i) => (
                  <View key={i} style={styles.ingredientCardWrapper}>
                    <IngredientCard
                      key={ingredient.id || i}
                      name={ingredient.name}
                      image={`https://spoonacular.com/cdn/ingredients_100x100/${ingredient.image}`}
                      amount={ingredient.amount}
                      unit={ingredient.measures?.us.unit_short}
                      showAddButton={true}
                      onAddPress={() => addIngredientToInventory(ingredient)}
                    />
                  </View>
                ))}
              </View>
            </ScrollView>
          </View>
          <View style={styles.fullInstructions}>
            <Text style={styles.subheading}>Cooking Steps</Text>
            {recipeDetails.analyzed_instructions &&
            recipeDetails.analyzed_instructions[0] &&
            recipeDetails.analyzed_instructions[0].steps ? (
              recipeDetails.analyzed_instructions[0].steps.map(
                ({ step, number }) => (
                  <View key={number} style={styles.instruction}>
                    <Text style={styles.instructionNumber}>{number}</Text>
                    <Text style={styles.instructionText}>{step}</Text>
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
    borderRadius: 100,
    padding: 8,
    width: 50,
    justifyContent: "center",
    alignItems: "center",
    position: "absolute",
    right: 10,
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
    fontSize: 27,
    fontWeight: "bold",
    color: "white",
    marginBottom: 10,
  },
  details: {
    flexDirection: "column",
    justifyContent: "space-between",
    alignItems: "flex-start",
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
  horizontalScroll: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "flex-start",
  },
  ingredientCardWrapper: {
    width: 90,
    marginBottom: 10,
    marginRight: 10,
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
    paddingRight: 15,
  },
  instructionNumber: {
    fontSize: 24,
    fontWeight: "bold",
    color: "white",
    marginRight: 10,
  },
  instructionText: {
    fontSize: 16,
    color: "white",
    flex: 1,
    flexWrap: "wrap",
    paddingLeft: 8,
  },
});

export default RecipePage;