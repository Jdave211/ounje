import React, { useState, useEffect } from "react";
import { View, Text, StyleSheet, Image, TouchableOpacity } from "react-native";
import { Entypo } from "@expo/vector-icons";
import Toast from "react-native-toast-message";
import { get_recipe_details } from "../utils/spoonacular";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { supabase } from "../utils/supabase";

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

const RecipeCard = ({ id }) => {
  const [user_id, setUserId] = useState(null);
  const [recipeDetails, setRecipeDetails] = useState(null);
  const [isSaved, setIsSaved] = React.useState(false);

  useEffect(() => {
    const get_user_id = async () => {
      let retrieved_user_id = await AsyncStorage.getItem("user_id");
      setUserId(() => retrieved_user_id);
    };

    const fetch_recipe_details = async () => {
      const detail = await get_recipe_details(id);
      console.log({ detail });
      setRecipeDetails(() => detail);

      const { data: saved_data } = await supabase
        .from("saved_recipes")
        .select()
        .eq("user_id", user_id)
        .eq("recipe_id", detail.id)
        .throwOnError();

      console.log({ saved_data });
    };

    if (!user_id) {
      get_user_id();
    } else {
      fetch_recipe_details();
    }
  }, [user_id]);

  console.log({ recipeDetails });
  const handleSave = () => {
    setIsSaved(!isSaved);
    if (isSaved) {
      Toast.show({
        type: "success",
        text1: "Recipe Unsaved",
        text2: `${recipe.title} has been unsaved from your recipes.`,
      });
      return;
    } else {
      Toast.show({
        type: "success",
        text1: "Recipe Saved",
        text2: `${recipe.title} has been saved to your recipes.`,
      });
    }
  };

  return (
    <View style={styles.container}>
      {recipeDetails && (
        <View style={styles.recipeContent}>
          <View style={styles.imageTextContainer}>
            <Text style={styles.title}>{recipeDetails.title}</Text>
            <Image style={styles.image} source={{ uri: recipeDetails.image }} />
          </View>
          <View style={styles.underHeading}>
            <View style={{ flexDirection: "row" }}>
              <Text style={styles.subheading}> Duration: </Text>
              <Text style={styles.text}>
                {recipeDetails.readyInMinutes} minutes
              </Text>
            </View>
            <Text style={styles.subheading}>Ingredients:</Text>
            {/* {recipeDetails.usedIngredients.map((ingredient, index) => (
              <Text style={styles.text} key={index}>
                {ingredient.originalName}
              </Text>
            ))} */}
            <Text style={styles.subheading}>Instructions:</Text>
            {/* <Text style={styles.text}>{recipeDetails.instructions[0]}</Text> */}
            <TouchableOpacity style={styles.save} onPress={handleSave}>
              <Entypo
                name="bookmark"
                size={24}
                color={isSaved ? "green" : "white"}
              />
            </TouchableOpacity>
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
    fontSize: 24,
    fontWeight: "bold",
    marginRight: 20,
    color: "black",
    textDecorationLine: "underline",
  },
  recipeContent: {
    backgroundColor: "#c7a27c",
    padding: 10,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: "black",
  },
  underHeading: {
    marginTop: -28,
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
    color: "black",
  },
  text: {
    fontSize: 16,
    color: "white",
  },
  save: {
    alignSelf: "flex-end",
    marginBottom: -20,
  },
});

export default RecipeCard;
