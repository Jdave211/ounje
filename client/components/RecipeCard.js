import React, { useState, useEffect, useMemo } from "react";
import { View, Text, StyleSheet, Image, TouchableOpacity } from "react-native";
import { AntDesign, Feather, MaterialIcons } from "@expo/vector-icons";
import Toast from "react-native-toast-message";
import { supabase } from "../utils/supabase";
import harvestImage from "../assets/harvest.png";
import { AnimatedCircularProgress } from "react-native-circular-progress";
import { Bar as ProgressBar } from "react-native-progress";
import { FOOD_ITEMS } from "../utils/constants";
import fridge_bg from "@assets/fridge_bg.jpg";
import { useAppStore } from "@stores/app-store";
import { useQuery } from "react-query";
import { fetchRecipeDetails } from "@utils/spoonacular";
import { fetchIsRecipeSavedByUser } from "@utils/supabase";
import { usePercentageOfIngredientsOwned } from "../hooks/usePercentageOfIngredientsOwned";

const RecipeCard = ({
  id: recipe_id,
  showBookmark,
  title,
  summary,
  imageUrl,
  readyInMinutes,
  servings,
  calories,
}) => {
  const [isRecipeSaved, setIsRecipeSaved] = useState(false);

  const user_id = useAppStore((state) => state.user_id);

  // here in useQuery, "recipeDetails" acts as the key for the cache and the
  // second parameter is a dynamic parameter used to refetch the data when the recipe_id changes
  const { data: recipeDetails } = useQuery(
    ["recipeDetails", recipe_id],
    async () => await fetchRecipeDetails(recipe_id)
  );

  useQuery(
    ["isRecipeSaved", user_id],
    async () => await fetchIsRecipeSavedByUser(user_id, recipe_id),
    {
      onSuccess: (isAlreadySaved) => {
        if (isAlreadySaved) setIsRecipeSaved(true);
      },
    }
  );

  const percentage = usePercentageOfIngredientsOwned(recipeDetails);

  const handleSave = async () => {
    let shouldSave = !isRecipeSaved;

    setIsRecipeSaved(shouldSave);

    if (shouldSave) {
      await supabase
        .from("saved_recipes")
        .insert([
          {
            user_id,
            recipe_id: recipeDetails ? recipeDetails.id : recipe_id,
          },
        ])
        .throwOnError();

      Toast.show({
        type: "success",
        text1: "Recipe Saved",
        text2: `${
          title || recipeDetails.title
        } has been saved to your recipes.`,
      });

      return;
    } else {
      await supabase
        .from("saved_recipes")
        .delete()
        .eq("user_id", user_id)
        .eq("recipe_id", recipeDetails ? recipeDetails.id : recipe_id)
        .throwOnError();
      Toast.show({
        type: "success",
        text1: "Recipe Unsaved",
        text2: `${
          title || recipeDetails.title
        } has been removed from your saved recipes.`,
      });
    }
  };

  return (
    <View style={styles.container}>
      {recipeDetails || title ? (
        <View
          style={{
            borderRadius: 10,
            borderWidth: 1,
            padding: 5,
            margin: 10,
            backgroundColor: "#2e2d2d",
          }}
        >
          <View style={{ width: "100%", padding: 0 }}>
            <Image
              style={{
                width: "100%",
                height: 150,
                borderRadius: 10,
                borderTopLeftRadius: 10,
                borderTopRightRadius: 10,
              }}
              source={{ uri: imageUrl || recipeDetails?.image }}
            />
          </View>
          <View style={{ padding: 10 }}>
            <View style={{ ...styles.imageTextContainer, marginBottom: 5 }}>
              <Text style={styles.title} numberOfLines={1}>
                {title || recipeDetails.title}
              </Text>
            </View>
            <View
              style={{
                flexDirection: "row",
                justifyContent: "space-between",
                alignItems: "center",
              }}
            >
              <View
                style={{
                  flexDirection: "row",
                  alignItems: "center",
                }}
              >
                <View
                  style={{
                    flexDirection: "row",
                    alignItems: "center",
                    paddingRight: 20,
                  }}
                >
                  <Feather name="clock" size={20} color="white" />
                  <Text style={{ ...styles.text, marginLeft: 10 }}>
                    {readyInMinutes || recipeDetails.ready_in_minutes} mins
                  </Text>
                </View>
                <View>
                  <Text style={styles.text}>
                    {new Number(percentage).toFixed(0)}% of{" "}
                  </Text>
                  <ProgressBar
                    color="green"
                    progress={percentage / 100}
                    width={60}
                  />
                </View>
                <View style={{ marginLeft: 7 }}>
                  <Image
                    source={harvestImage}
                    style={{ resizeMode: "cover", width: 24, height: 24 }}
                  />
                </View>
              </View>
              {showBookmark && (
                <View>
                  <TouchableOpacity
                    style={styles.saveButton}
                    onPress={handleSave}
                  >
                    {isRecipeSaved ? (
                      <MaterialIcons
                        name="bookmark-add"
                        size={24}
                        color="green"
                      />
                    ) : (
                      <MaterialIcons
                        name="bookmark-border"
                        size={24}
                        color="white"
                      />
                    )}
                  </TouchableOpacity>
                </View>
              )}
            </View>
          </View>
        </View>
      ) : null}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  title: {
    fontSize: 20,
    fontWeight: "bold",
    marginRight: 20,
    color: "white",
  },
  recipeContent: {
    backgroundColor: "#c7a27c",
    padding: 10,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "white",
  },
  imageTextContainer: {
    flexDirection: "row",
  },
  image: {
    width: 100,
    height: 100,
    marginLeft: 15,
  },
  subheading: {
    fontSize: 18,
    fontWeight: "bold",
    marginBottom: 5,
    color: "white",
  },
  text: {
    fontSize: 16,
    color: "white",
  },
  save: {
    alignSelf: "flex-end",
  },
});

export default RecipeCard;
