import React from 'react';
import { View, Text, StyleSheet } from 'react-native';

const RecipeCard = ({ recipe }) => {
    const generatedRecipes = 
        {
          "name": "Easy Veggie Pasta",
          "image_prompt": "A bowl of colorful pasta with mixed vegetables, topped with grated cheese, and garnished with a sprig of parsley.",
          "duration": 30,
          "servings": 4,
          "ingredients": [
            {"name": "boxed pasta", "quantity": 1, "displayed_text": "1 box of pasta", "already_have": false},
            {"name": "canned tomatoes", "quantity": 1, "displayed_text": "1 can of tomatoes", "already_have": false},
            {"name": "frozen mixed vegetables", "quantity": 1, "displayed_text": "1 bag of frozen mixed vegetables", "already_have": false},
            {"name": "cheese blocks", "quantity": 1, "displayed_text": "1 block of cheese (for grating)", "already_have": false}
          ],
          "instructions": [
            "Bring a large pot of water to a boil. Add a pinch of salt and the boxed pasta. Cook according to the package instructions until al dente.",
            "While the pasta is cooking, in a separate pan, heat the canned tomatoes over medium heat until they start to simmer.",
            "Add the frozen mixed vegetables to the tomato sauce, and cook until the vegetables are heated through, about 5-7 minutes.",
            "Drain the cooked pasta and return it to the pot. Pour the vegetable-tomato sauce over the pasta and mix well.",
            "Grate the cheese block and sprinkle it over the pasta before serving."
          ]
        };

        return (
          <View style={styles.container}>
              <Text style={styles.name}>{generatedRecipes.name}</Text>
              <Text style={styles.subheading}>Ingredients:</Text>
              {generatedRecipes.ingredients.map((ingredient, index) => (
                  <Text style ={styles.text} key={index}>{ingredient.displayed_text}</Text>
              ))}
              <Text style={styles.subheading}>Instructions:</Text>
              <Text style={styles.text}>{generatedRecipes.instructions[0]}</Text>
          </View>
      );
    }

    const styles = StyleSheet.create({
        container: {
            borderColor: 'green',
            borderWidth: 1,
            borderRadius: 10,
            padding: 10,
        },
        name: {
            color: 'green',
            fontSize: 20,
            fontWeight: 'bold',
        },
        subheading: {
            color: 'white',
            fontSize: 15,
            fontWeight: 'bold',
        },
        text: {
            color: 'white',
            fontSize: 10,
            fontWeight: 'semi-bold',
        },
    });

export default RecipeCard;