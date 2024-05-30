import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  StyleSheet,
  Image,
  TouchableOpacity,
  ImageBackground,
  Dimensions,
  FlatList,
} from "react-native";
import { AntDesign, Feather, MaterialIcons } from "@expo/vector-icons";
import Toast from "react-native-toast-message";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { supabase } from "../utils/supabase";
import Carousel from "react-native-reanimated-carousel";
import { ScrollView } from "react-native-gesture-handler";
import { entitle } from "../utils/helpers";
import harvestImage from "../assets/harvest.png";
import { Bar as ProgressBar } from "react-native-progress";
import RenderHtml from "react-native-render-html";
import { useWindowDimensions } from "react-native";

import { useNavigation } from "@react-navigation/native";

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

const RecipePage = ({ route }) => {
  const { width: WIDTH } = useWindowDimensions();
  const { id } = route.params;
  const navigation = useNavigation();
  const PAGE_WIDTH = Dimensions.get("window").width;
  const [user_id, setUserId] = useState(null);
  const [recipeDetails, setRecipeDetails] = useState(null);
  const [food_items, setFoodItems] = useState([]);
  const [isSaved, setIsSaved] = React.useState(false);

  console.log("RecipePage", { id });
  useEffect(() => {
    const get_user_id = async () => {
      let retrieved_user_id = await AsyncStorage.getItem("user_id");
      setUserId(() => retrieved_user_id);
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

    const fetch_food_items = async () => {
      retrieved_text = await AsyncStorage.getItem("food_items_array");
      let retrieved_food_items_array = JSON.parse(retrieved_text);

      if (retrieved_food_items_array?.length > 0) {
        setFoodItems(retrieved_food_items_array);
      }
    };

    const fetch_is_saved = async () => {
      const { data: saved_data } = await supabase
        .from("saved_recipes")
        .select()
        .eq("user_id", user_id)
        .eq("recipe_id", id)
        .throwOnError();

      setIsSaved(saved_data?.length > 0);
    };

    if (!user_id) {
      get_user_id();
    } else {
      fetch_recipe_details();
      fetch_is_saved();
      fetch_food_items();
    }
  }, [user_id, route.params]);

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

  const on_return_to_previous_page = () => {
    console.log({ navigation: navigation.getState().history });
    navigation.goBack();
  };

  console.log({ recipePage: recipeDetails });

  const calc_percentage = (recipeDetails) => {
    if (!recipeDetails || !food_items) return 0;

    let food_items_set = new Set(
      food_items.map(({ spoonacular_id }) => spoonacular_id)
    );

    const owned_items = recipeDetails.extended_ingredients.filter(
      (ingredient) => food_items_set.has(ingredient.id)
    );

    if (!owned_items || owned_items.length === 0) return 0;

    const _percentage =
      (owned_items.length / recipeDetails.extended_ingredients.length) * 100;

    return _percentage;
  };

  const percentage = useMemo(
    () => calc_percentage(recipeDetails) * 2,
    [food_items, recipeDetails]
  );

  return (
    recipeDetails && (
      <ScrollView
        style={styles.container}
        stickyHeaderIndices={[0]}
        showsVerticalScrollIndicator={false}
      >
        <View
          style={{
            width: "100%",
            position: "absolute",
            // flex: 1,
            flexDirection: "row",
            justifyContent: "space-between",
            // backgroundColor: "red",
            height: 50,
          }}
        >
          <TouchableOpacity
            style={{
              backgroundColor: "#2e2d2d",
              borderRadius: 100,
              padding: 8,
              width: 50,
              justifyContent: "center",
              alignItems: "center",
              marginLeft: 10,
            }}
            onPress={on_return_to_previous_page}
          >
            <AntDesign name="arrowleft" size={24} color={"white"} />
          </TouchableOpacity>

          <TouchableOpacity
            style={{
              backgroundColor: "#2e2d2d",
              borderRadius: 100,
              padding: 8,
              width: 50,
              top: -40,
              justifyContent: "center",
              alignItems: "center",
              marginLeft: "auto",
              marginRight: 10,
            }}
            onPress={handleSave}
          >
            {isSaved ? (
              <MaterialIcons name="bookmark-remove" size={24} color={"gray"} />
            ) : (
              <MaterialIcons name="bookmark-add" size={24} color={"green"} />
            )}
          </TouchableOpacity>
        </View>

        <View>
          <Carousel
            loop
            width={PAGE_WIDTH}
            height={PAGE_WIDTH / 2}
            // autoPlay={true}
            data={[0]}
            scrollAnimationDuration={1000}
            onSnapToItem={(index) => console.log("current index:", index)}
            renderItem={({ index }) => (
              <View
                style={{
                  flex: 1,
                  borderWidth: 1,
                  justifyContent: "center",
                }}
              >
                <Image
                  style={{
                    width: "100%",
                    height: 200,
                    borderRadius: 10,
                    borderTopLeftRadius: 10,
                    borderTopRightRadius: 10,
                  }}
                  source={{ uri: recipeDetails.image }}
                />
              </View>
            )}
          />
        </View>

        <View style={{ padding: 10 }}>
          <View style={{ ...styles.imageTextContainer, marginBottom: 5 }}>
            <Text style={styles.title}>{recipeDetails.title}</Text>
          </View>
          <View
            style={{
              flexDirection: "row",
              justifyContent: "space-between",
              alignItems: "center",
              marginTop: 10,
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
                <Feather name="clock" size={20} color="green" />
                <Text style={{ ...styles.text, marginLeft: 10 }}>
                  {recipeDetails.ready_in_minutes} mins
                </Text>
              </View>

              <View>
                <Text style={{ ...styles.text, marginRight: 10 }}>
                  {new Number(percentage).toFixed(2)}% of Ingredients
                </Text>
                <ProgressBar progress={percentage / 100} width={160} />
              </View>
              <View>
                <Image
                  source={harvestImage}
                  style={{ resizeMode: "cover", width: 24, height: 24 }}
                />
              </View>
            </View>
          </View>
          <View style={{ marginTop: 20 }}>
            <Text style={styles.subheading}>Description</Text>

            <Text style={styles.text} numberOfLines={2}>
              <RenderHtml
                contentWidth={WIDTH}
                source={{ html: recipeDetails.summary }}
              />
              {recipeDetails.summary}
            </Text>
          </View>

          <View style={{ marginTop: 20 }}>
            <Text style={styles.subheading}>Ingredients</Text>
            {recipeDetails.extended_ingredients.map((ingredient, i) => (
              <View
                key={i}
                style={{
                  flex: 3,
                  flexDirection: "row",
                  alignItems: "center",
                  justifyContent: "space-between",
                  paddingTop: 10,
                  paddingBottom: 10,
                }}
              >
                <View
                  style={{
                    flexDirection: "row",
                    alignItems: "center",
                  }}
                >
                  <Image
                    style={{
                      width: 50,
                      height: 50,
                      borderRadius: 10,
                      marginRight: 10,
                      backgroundColor: "white",
                    }}
                    source={{
                      uri:
                        "https://img.spoonacular.com/ingredients_100x100/" +
                        ingredient.image,
                    }}
                  />
                  <Text style={styles.text}>{entitle(ingredient.name)}</Text>
                </View>
                <View>
                  <Text style={styles.text}>
                    {ingredient.amount} {ingredient.unit}
                  </Text>
                </View>
              </View>
            ))}
          </View>

          <View style={{ marginTop: 20 }}>
            <Text style={styles.subheading}>Instructions</Text>
            {recipeDetails.analyzed_instructions[0].steps.map(
              ({ step, number }) => (
                <View
                  key={number}
                  style={{
                    flex: 2,
                    flexDirection: "row",
                    alignItems: "flex-start",
                    width: "100%",
                    paddingTop: 8,
                  }}
                >
                  <Text style={{ ...styles.text, marginRight: 8 }}>
                    {number}.
                  </Text>
                  <Text style={styles.text}>{step}</Text>
                </View>
              )
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
    backgroundColor: "black",
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

export default RecipePage;
