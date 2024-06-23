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
import AsyncStorage from "@react-native-async-storage/async-storage";
import { supabase } from "../utils/supabase";
import { useNavigation } from "@react-navigation/native";

const SavedRecipes = () => {
  const navigation = useNavigation();
  const [user_id, setUserId] = useState(null);
  const [savedRecipes, setSavedRecipes] = useState([]);

  useEffect(() => {
    const get_user_id = async () => {
      let retrieved_user_id = await AsyncStorage.getItem("user_id");
      setUserId(() => retrieved_user_id);
    };

    const fetch_saved_recipes = async () => {
      const { data: recipes, error } = await supabase
        .from("saved_recipes")
        .select("recipe_id")
        .eq("user_id", user_id);
    
      if (error) {
        console.error("Error fetching saved recipes:", error);
        return;
      }
    
      console.log({ saved_recipes: recipes });
    
      if (recipes) {
        // Use a Set to store unique recipe_ids
        const uniqueRecipeIds = Array.from(new Set(recipes.map(({ recipe_id }) => recipe_id)));
    
        setSavedRecipes(uniqueRecipeIds);
      }
    };
    

    fetch_saved_recipes();

    if (!user_id) {
      get_user_id();
    } else {
      fetch_saved_recipes();
    }
  }, [user_id]);

  const navigate_to_recipe_page = (recipe_id) => () => {
    navigation.navigate("RecipePage", { id: recipe_id });
    console.log("Navigating to recipe page with id: ", recipe_id);
  };

  return (
    <View style={styles.container}>
      <View style={{ marginBottom: 10 }}>
        <Text style={styles.text}> Saved Recipes </Text>
      </View>
      {savedRecipes && (
        <ScrollView>
          {/* <View
          style={{
            flexDirection: "row",
            flexWrap: "wrap",
            justifyContent: "space-around",
          }}
        > */}
          {savedRecipes.map((recipe_id, i) => (
            // <View key={i} style={{ width: 200, margin: 10 }}>
            <TouchableOpacity
              key={i}
              onPress={navigate_to_recipe_page(recipe_id)}
            >
              <RecipeCard id={recipe_id} isaved={true} showBookmark={true} />
            </TouchableOpacity>
            // </View>
          ))}
          {/* </View> */}
        </ScrollView>
      )}
    </View>
  );
};

const styles = {
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
};

export default SavedRecipes;
