import React, { useState, useEffect, useMemo } from "react";
import { View, Text, StyleSheet, Image, TouchableOpacity } from "react-native";
import { AntDesign, Feather, MaterialIcons } from "@expo/vector-icons";
import Toast from "react-native-toast-message";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { supabase } from "../utils/supabase";
import harvestImage from "../assets/harvest.png";
import { AnimatedCircularProgress } from "react-native-circular-progress";
import { Bar as ProgressBar } from "react-native-progress";
import { FOOD_ITEMS } from "../utils/constants";

// recipe:
// - id
// usedIngredients: [],
// missedIngredients: [],
// title: Text,
// image: Text,
// usedIngredientCount: Number,
// missedIngredientCount: Number,
//
// retrieve from database if recipes are stored
// - likes: Number
// - bookmarks: Number
//

const RecipeCard = ({ id, showBookmark }) => {
  const [user_id, setUserId] = useState(null);
  const [recipeDetails, setRecipeDetails] = useState(null);
  const [isSaved, setIsSaved] = React.useState(false);
  const [food_items, setFoodItems] = useState([]);

  useEffect(() => {
    const get_user_id = async () => {
      let retrieved_user_id = await AsyncStorage.getItem("user_id");
      setUserId(() => retrieved_user_id);
    };

    const fetch_food_items = async () => {
      retrieved_text = await AsyncStorage.getItem("food_items_array");
      let retrieved_food_items_array = JSON.parse(retrieved_text);

      if (retrieved_food_items_array?.length > 0) {
        setFoodItems(retrieved_food_items_array);
      }
    };

    const fetch_recipe_details = async () => {
      const {
        data: [recipe],
      } = await supabase
        .from("recipe_ids")
        .select("*")
        .eq("id", id)
        .throwOnError();

      setRecipeDetails(() => recipe);
    };

    const fetch_is_saved = async () => {
      const { data: saved_data } = await supabase
        .from("saved_recipes")
        .select()
        .eq("user_id", user_id)
        .eq("recipe_id", id)
        .throwOnError();

      console.log({ saved_data });
    };

    if (!user_id) {
      get_user_id();
    } else {
      fetch_recipe_details();
      fetch_is_saved();
      fetch_food_items();
    }
  }, [user_id]);

  console.log({ recipeDetails });

  const handleSave = async () => {
    let localIsSaved = !isSaved;

    console.log({ localIsSaved });
    setIsSaved(localIsSaved);

    if (localIsSaved) {
      await supabase
        .from("saved_recipes")
        .insert([{ user_id, recipe_id: recipeDetails.id }])
        .throwOnError();

      Toast.show({
        type: "success",
        text1: "Recipe Saved",
        text2: `${recipeDetails.title} has been saved to your recipes.`,
      });

      return;
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
        text2: `${recipeDetails.title} has been removed from your saved recipes.`,
      });
    }
  };

  const calc_percentage = (recipeDetails) => {
    if (!recipeDetails || !food_items) return 0;

    let food_items_set = new Set(
      food_items.map(({ spoonacular_id }) => spoonacular_id),
    );

    const owned_items = recipeDetails.extended_ingredients.filter(
      (ingredient) => food_items_set.has(ingredient.id),
    );

    if (!owned_items || owned_items.length === 0) return 0;

    const _percentage =
      (owned_items.length / recipeDetails.extended_ingredients.length) * 100;

    return _percentage;
  };

  const percentage = useMemo(
    () => calc_percentage(recipeDetails),
    [food_items, recipeDetails],
  );

  return (
    <View style={styles.container}>
      {recipeDetails && (
        <View
          style={{
            // borderColor: "white",
            borderRadius: 10,
            borderWidth: 1,
            padding: 5,
            borderShadow: "5px 10px #ffffff",
            flex: 2,
            margin: 10,
            backgroundColor: "#2e2d2d",
          }}
        >
          <View
            style={{
              width: "100%",
              // borderRadius: 10,
              padding: 0,
              // borderColor: "white",
              // borderWidth: 1,
            }}
          >
            <Image
              style={{
                width: "100%",
                height: 150,
                borderRadius: 10,
                borderTopLeftRadius: 10,
                borderTopRightRadius: 10,
              }}
              source={{ uri: recipeDetails.image }}
            />
          </View>
          <View style={{ padding: 10 }}>
            <View style={{ ...styles.imageTextContainer, marginBottom: 5 }}>
              <Text style={styles.title} numberOfLines={1}>
                {recipeDetails.title}
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
                    {recipeDetails.ready_in_minutes} mins
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
                  <TouchableOpacity style={styles.save} onPress={handleSave}>
                    {isSaved ? (
                      <MaterialIcons
                        name="bookmark-added"
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
      )}
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
    // textDecorationLine: "underline",
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
