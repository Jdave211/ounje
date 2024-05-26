import React from "react";
import { View, Text, StyleSheet, Image, TouchableOpacity } from "react-native";
import { Entypo } from "@expo/vector-icons";
import Toast from "react-native-toast-message";

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

const RecipeCard = ({ recipe, onBookmark }) => {
  // const [recipeDetails, setRecipeDetails] = useState(null);
  const [isSaved, setIsSaved] = React.useState(false);

  // useEffect()
  const handleSave = () => {
    let localIsSaved = !isSaved;

    console.log({ localIsSaved });
    setIsSaved(localIsSaved);
    onBookmark(recipe, localIsSaved);

    if (localIsSaved) {
      Toast.show({
        type: "success",
        text1: "Recipe Saved",
        text2: `${recipe.title} has been saved to your recipes.`,
      });

      return;
    } else {
      Toast.show({
        type: "success",
        text1: "Recipe Unsaved",
        text2: `${recipe.title} has been unsaved from your recipes.`,
      });
    }
  };

  return (
    <View style={styles.container}>
      <View style={styles.recipeContent}>
        <View style={styles.imageTextContainer}>
          <Text style={styles.title}>{recipe.title}</Text>
          <Image style={styles.image} source={{ uri: recipe.image }} />
        </View>
        <View style={styles.underHeading}>
          <View style={{ flexDirection: "row" }}>
            <Text style={styles.subheading}> Duration: </Text>
            {/* <Text style={styles.text}>{recipe.duration} minutes</Text> */}
          </View>
          <Text style={styles.subheading}>Ingredients:</Text>
          {recipe.usedIngredients.map((ingredient, index) => (
            <Text style={styles.text} key={index}>
              {ingredient.originalName}
            </Text>
          ))}
          <Text style={styles.subheading}>Instructions:</Text>
          {/* <Text style={styles.text}>{recipe.instructions[0]}</Text> */}
          <TouchableOpacity style={styles.save} onPress={handleSave}>
            <Entypo
              name="bookmark"
              size={24}
              color={isSaved ? "green" : "white"}
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
