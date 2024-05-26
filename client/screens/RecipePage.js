import React, { useState, useEffect } from "react";
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
  const { id } = route.params;
  const navigation = useNavigation();
  const PAGE_WIDTH = Dimensions.get("window").width;
  const [user_id, setUserId] = useState(null);
  const [recipeDetails, setRecipeDetails] = useState(null);
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
    }
  }, [user_id, route.params]);

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

  const on_return_to_previous_page = () => {
    console.log({ navigation: navigation.getState().history });
    navigation.goBack();
  };

  const on_bookmark_click = () => {};

  console.log({ recipePage: recipeDetails });
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
            onPress={on_bookmark_click}
          >
            <Feather name="bookmark" size={24} color={"white"} />
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
                <Text style={styles.text}>29% of [II]</Text>
              </View>
            </View>
          </View>
          <View>
            <Text style={styles.subheading}>Description</Text>

            <Text style={styles.text} numberOfLines={2}>
              {recipeDetails.summary}
            </Text>
          </View>

          <View>
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

          <View>
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

      // <View>
      //   <Image
      //     style={{
      //       width: "100%",
      //       height: 200,
      //       borderRadius: 10,
      //       borderTopLeftRadius: 10,
      //       borderTopRightRadius: 10,
      //     }}
      //     source={{ uri: recipeDetails.image }}
      //   />
      //   {/* <View
      //     style={{
      //       width: "100%",
      //       // borderRadius: 10,
      //       padding: 0,
      //       // borderColor: "white",
      //       // borderWidth: 1,
      //     }}
      //   ></View>
      //   <View style={{ padding: 10 }}>
      //     <View style={{ ...styles.imageTextContainer, marginBottom: 5 }}>
      //       <Text style={styles.title} numberOfLines={1}>
      //         {recipeDetails.title}
      //       </Text>
      //     </View>
      //     <View
      //       style={{
      //         flexDirection: "row",
      //         justifyContent: "space-between",
      //         alignItems: "center",
      //       }}
      //     >
      //       <View
      //         style={{
      //           flexDirection: "row",
      //           alignItems: "center",
      //         }}
      //       >
      //         <View
      //           style={{
      //             flexDirection: "row",
      //             alignItems: "center",
      //             paddingRight: 20,
      //           }}
      //         >
      //           <Feather name="clock" size={20} color="green" />
      //           <Text style={{ ...styles.text, marginLeft: 10 }}>
      //             {recipeDetails.ready_in_minutes} mins
      //           </Text>
      //         </View>

      //         <View>
      //           <Text style={styles.text}>29% of [II]</Text>
      //         </View>
      //       </View>

      //       <View>
      //         <TouchableOpacity style={styles.save} onPress={handleSave}>
      //           {isSaved ? (
      //             <MaterialIcons
      //               name="bookmark-added"
      //               size={24}
      //               color="green"
      //             />
      //           ) : (
      //             <MaterialIcons
      //               name="bookmark-border"
      //               size={24}
      //               color="white"
      //             />
      //           )}
      //         </TouchableOpacity>
      //       </View>
      //     </View>
      //   </View> */}
      // </View>
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
