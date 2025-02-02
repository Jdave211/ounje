// TalkToRecipe.js
import React, { useState } from 'react';
import {
  View,
  Text,
  TextInput,
  StyleSheet,
  TouchableOpacity,
  Keyboard,
  Dimensions,
  Alert,
  ActivityIndicator,
} from 'react-native';
import { extract_recipe_from_website, format_recipe } from '../../utils/spoonacular'; // Adjust the import path as necessary
import { useNavigation } from '@react-navigation/native';
import { supabase } from '../../utils/supabase'; // Import supabase

export default function TalkToRecipe() {
  const [recipeUrl, setRecipeUrl] = useState('');
  const [loading, setLoading] = useState(false);
  const navigation = useNavigation(); // Hook to navigate between screens

  const handleTalkToRecipe = async () => {
    if (!recipeUrl) {
      Alert.alert('Invalid Input', 'Please enter a recipe URL');
      return;
    }
    Keyboard.dismiss();
    console.log('Recipe URL:', recipeUrl);

    try {
      setLoading(true);

      // Call the extract_recipe_from_website function with the URL
      const extractedRecipe = await extract_recipe_from_website(recipeUrl);

      // Console log the extracted recipe
      console.log('Extracted Recipe:', extractedRecipe);

      // Format the recipe to match the database schema
      const formattedRecipe = format_recipe(extractedRecipe);

      // Store the formatted recipe in the database
      const { data: storedRecipe, error } = await supabase
        .from('recipe_ids')
        .upsert([formattedRecipe], {
          onConflict: 'spoonacular_id',
        })
        .select()
        .throwOnError();

      if (error || !storedRecipe || storedRecipe.length === 0) {
        console.error('Error storing recipe:', error);
        Alert.alert('Error', 'Failed to store recipe. Please try again.');
        return;
      }

      // Navigate to the RecipePage, passing the recipe ID
      navigation.navigate('RecipePage', { id: storedRecipe[0].id });

    } catch (error) {
      console.error('Error extracting recipe:', error);
      Alert.alert('Error', 'Failed to extract recipe. Please try again.');
    } finally {
      setLoading(false);
    }
  };

  const { width } = Dimensions.get('window');

  return (
    <View style={styles.container}>
      <View style={styles.content}>
        <TextInput
          style={styles.textInput}
          placeholder="Paste your recipe URL here"
          placeholderTextColor="#aaa"
          value={recipeUrl}
          onChangeText={setRecipeUrl}
          autoCapitalize="none"
          autoCorrect={false}
          keyboardType="url"
          returnKeyType="done"
          onSubmitEditing={handleTalkToRecipe}
        />
        <Text style={styles.instructions}>
          Paste the URL of the recipe you would like to add.
        </Text>
        <TouchableOpacity style={styles.button} onPress={handleTalkToRecipe}>
          {loading ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.buttonText}>Add your recipe</Text>
          )}
        </TouchableOpacity>
      </View>
    </View>
  );
}

const { width } = Dimensions.get('window');

const styles = StyleSheet.create({
  container: {
    flex: 1,
    paddingHorizontal: 7,
  },
  content: {
    alignItems: 'center', // Center content horizontally
  },
  textInput: {
    width: width * 0.9, // Responsive width
    height: 50,
    borderColor: 'white',
    borderWidth: 1,
    borderRadius: 10, // Slightly more rounded corners
    paddingHorizontal: 15,
    color: 'white',
    fontSize: 16,
  },
  instructions: {
    color: '#B0C4DE', // Light Steel Blue color
    fontSize: 14,
    marginTop: 10,
    textAlign: 'center',
    width: width * 0.85, // Responsive width
  },
  button: {
    backgroundColor: "#282C35",
    paddingVertical: 15,
    borderRadius: 10,
    marginTop: 30,
    alignItems: 'center',
    width: width * 0.8, // Responsive width
  },
  buttonText: {
    color: 'white',
    fontSize: 18,
    fontWeight: 'bold',
  },
});