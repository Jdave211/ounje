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
import RecipeCard from "@components/RecipeCard";
import RecipeOptionCard from "@components/RecipeOptionCard";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { supabase } from "../../utils/supabase";
import { useNavigation } from "@react-navigation/native";

const RecipeOptions = () => {
  const navigation = useNavigation();

  const [user_id, setUserId] = useState(null);
  const [recipeOptions, setRecipeOptions] = useState([]);

  useEffect(() => {
    const get_user_id = async () => {
      let retrieved_user_id = await AsyncStorage.getItem("user_id");
      setUserId(() => retrieved_user_id);
    };

    const fetch_recipe_options = async () => {
      let retrieved_text = await AsyncStorage.getItem("recipe_options");
      let retrieved_recipe_options = JSON.parse(retrieved_text);

      console.log({ retrieved_text });
      if (retrieved_recipe_options?.length > 0) {
        setRecipeOptions(() => retrieved_recipe_options);
      }
    };

    if (!user_id) {
      get_user_id();
    } else {
      fetch_recipe_options();
    }
  }, [user_id]);

  const store_selected_recipes = async (selected_recipes) => {
    const recipe_image_bucket = "recipe_images";

    // const recipe_image_gen_data = selected_recipes.map((recipe) => ({
    //   prompt:
    //     "a zoomed out image showing the full dish of " + recipe.image_prompt,
    //   storage_path: `${current_run.id}/${recipe.name}.jpeg`,
    // }));

    // generate and store images for each recipe
    // shoot and forget approach
    // no need to wait for the images to be generated or stored
    // we just let them run while we continue with the rest of the process
    // the urls to the image can be calculated from the storage path
    // so we can pass that into the app and it can fetch the images as needed
    await Promise.allSettled(
      selected_recipes.map(async (recipe) => {
        let recipe_image = await generate_image(
          "a zoomed out image showing the full dish of " + recipe.image_prompt
        );

        let storage_path = `${current_run.id}/${recipe.name}.jpeg`;
        let image_storage_response = await store_image(
          recipe_image_bucket,
          storage_path,
          recipe_image
        );

        return image_storage_response;
      })
    );

    const recipe_records = selected_recipes.map((recipe) => {
      delete recipe.image_prompt;
      let storage_path = `${current_run.id}/${recipe.name}.jpeg`;

      let {
        data: { publicUrl: image_url },
      } = supabase.storage.from(recipe_image_bucket).getPublicUrl(storage_path);

      recipe["image_url"] = image_url;

      return recipe;
    });

    console.log("recipe_records: ", recipe_records);

    return await supabase
      .from("recipes")
      .upsert(recipe_records, { onConflict: ["name"] })
      .throwOnError();
  };

  const navigate_to_saved_recipes = () => {
    navigation.navigate("SavedRecipes");
  };

  console.log({ recipeOptions });

  return (
    <View style={styles.container}>
      <Text style={styles.text}>Generated Recipe Options</Text>
      <ScrollView>
        {/* <View style={{ justifyContent: "center", alignItems: "center", flexDirection: "row", flexWrap: "wrap" }}> */}
        {recipeOptions.map((recipeOption, index) => (
          <View key={index}>
            <RecipeCard
              key={index}
              id={recipeOption.id}
              // recipe={recipeOption}
              showBookmark={true}
            />
          </View>
        ))}
        {/* </View> */}
      </ScrollView>
      <View style={styles.buttonContainer}>
        <TouchableOpacity
          style={styles.buttonContainer}
          onPress={navigate_to_saved_recipes}
          // disabled={images.length === 0}
        >
          <Text style={styles.buttonText}>View Saved Recipes</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
};

const styles = {
  container: {
    flex: 1,
    backgroundColor: "black",
  },
  text: {
    color: "white",
    fontSize: 20,
  },
  buttonContainer: {
    width: 200,
    height: 50,
    backgroundColor: "green",
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
  },
  buttonText: {
    color: "#fff",
    fontWeight: "bold",
  },
};

export default RecipeOptions;
