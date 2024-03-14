import React, { useState } from 'react';
import { View, Text, StyleSheet, FlatList, TouchableOpacity, ScrollView, TouchableWithoutFeedback } from 'react-native';

const SavedRecipes = () => {
    const [recipes, setRecipes] = useState([
        { id: '1', name: 'Chicken Soup', details: 'Recipe details for Chicken Soup...' },
        { id: '2', name: 'Beef Stew', details: 'Recipe details for Beef Stew...' },
        { id: '3', name: 'Vegetable Stir Fry', details: 'Recipe details for Vegetable Stir Fry...' },
    ]);
    const [selectedRecipe, setSelectedRecipe] = useState(null);

    const handlePress = (recipe) => {
        setSelectedRecipe(recipe);
    };

    return (
        <TouchableWithoutFeedback onPress={() => setSelectedRecipe(null)}>
            <View style={styles.container}>
                <Text style={styles.text}>your recipes</Text>
                <FlatList 
                    data={recipes}
                    keyExtractor={item => item.id}
                    renderItem={({ item }) => (
                        <TouchableOpacity onPress={() => handlePress(item)}>
                            <View style={styles.recipeContainer}>
                                <Text style={styles.recipeText}>{item.name}</Text>
                            </View>
                        </TouchableOpacity>
                    )}
                />
                {selectedRecipe && (
                    <ScrollView style={styles.detailsContainer}>
                        <Text style={styles.detailsText}>{selectedRecipe.details}</Text>
                    </ScrollView>
                )}
            </View>
        </TouchableWithoutFeedback>
    );
};

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: 'black',
    },
    text: {
        color: 'green',
        fontSize: 20,
        textAlign: 'center',
        marginVertical: 10,
    },
    recipeContainer: {
        backgroundColor: 'gray',
        marginVertical: 10,
        padding: 20,
        borderRadius: 10,
    },
    recipeText: {
        color: 'black',
        fontSize: 18,
    },
    detailsContainer: {
        backgroundColor: 'white',
        padding: 20,
        marginVertical: 10,
    }
});

export default SavedRecipes;