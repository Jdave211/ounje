import React from 'react';
import { View, Text, StyleSheet } from 'react-native';

const SavedRecipes = () => {
    return (
        <View style={styles.container}>
            <Text style={styles.text}>Saved Recipes</Text>
        </View>
    )
};

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: 'black',
    },
    text: {
        color: 'white',
    },
});

export default SavedRecipes;