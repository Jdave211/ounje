import React, { useState } from "react";
import { View, Text, StyleSheet, Image, TouchableOpacity } from "react-native";
import pasta from "../assets/pasta.png";
import { FontAwesome } from "@expo/vector-icons";
import Toast from "react-native-toast-message";

const CommunityCard = () => {
  const [isLiked, setIsLiked] = useState(false);
  const handleLike = () => {
    setIsLiked(!isLiked);
    if (isLiked) {
      Toast.show({
        type: "success",
        text1: "Recipe Unliked",
        text2: `${generatedRecipes.name} has been unliked.`,
      });
    } else {
      Toast.show({
        type: "success",
        text1: "Recipe Liked",
        text2: `${generatedRecipes.name} has been liked.`,
      });
    }
  };
  const generatedRecipes = {
    name: "Easy Veggie Pasta",
    image_prompt:
      "A bowl of colorful pasta with mixed vegetables, topped with grated cheese, and garnished with a sprig of parsley.",
    duration: 30,
    servings: 4,
    rating: 6.5,
    ingredients: [
      {
        name: "boxed pasta",
        quantity: 1,
        displayed_text: "1 box of pasta",
        already_have: false,
      },
      {
        name: "canned tomatoes",
        quantity: 1,
        displayed_text: "1 can of tomatoes",
        already_have: false,
      },
      {
        name: "frozen mixed vegetables",
        quantity: 1,
        displayed_text: "1 bag of frozen mixed vegetables",
        already_have: false,
      },
      {
        name: "cheese blocks",
        quantity: 1,
        displayed_text: "1 block of cheese (for grating)",
        already_have: false,
      },
    ],
    instructions: [
      "Bring a large pot of water to a boil. Add a pinch of salt and the boxed pasta. Cook according to the package instructions until al dente.",
      "While the pasta is cooking, in a separate pan, heat the canned tomatoes over medium heat until they start to simmer.",
      "Add the frozen mixed vegetables to the tomato sauce, and cook until the vegetables are heated through, about 5-7 minutes.",
      "Drain the cooked pasta and return it to the pot. Pour the vegetable-tomato sauce over the pasta and mix well.",
      "Grate the cheese block and sprinkle it over the pasta before serving.",
    ],
  };

  return (
    <View style={styles.container}>
      <View style={styles.recipeContent}>
        <View style={styles.imageTextContainer}>
          <Text style={styles.name}>{generatedRecipes.name}</Text>
          <Image style={styles.image} source={pasta} />
        </View>
        <View style={styles.underHeading}>
          <View style={{ flexDirection: "row" }}>
            <Text style={styles.subheading}> Duration: </Text>
            <Text style={styles.text}>{generatedRecipes.duration} minutes</Text>
          </View>
          <View style={{ flexDirection: "row" }}>
            <Text style={styles.subheading}> Rating: </Text>
            <Text style={styles.text}>{generatedRecipes.rating} / 10</Text>
          </View>
          <TouchableOpacity style={styles.like} onPress={handleLike}>
            <FontAwesome
              name="heartbeat"
              size={30}
              color={isLiked ? "red" : "white"}
            />
          </TouchableOpacity>
        </View>
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  name: {
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
    flexDirection: "column",
  },
  underHeading: {
    marginTop: -20,
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
  like: {
    alignSelf: "flex-end",
    marginRight: 5,
  },
});

export default CommunityCard;
