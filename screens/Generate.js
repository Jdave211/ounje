import React from 'react';
import { View, Text, StyleSheet } from 'react-native';
import FoodRow from '../components/FoodRow';
import ImageUploadForm from '../components/ImageUploadForm';

const Generate = () => {
  return (
    <View style={styles.container}>
      <Text style={styles.text}>Generate Some Recipes</Text>
      <ImageUploadForm/>
      <View style={styles.foodRowContainer}>
        <FoodRow/>
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  text: {
    color: 'white',
  },
  foodRowContainer: {
    position: 'absolute', // Add this line
    bottom: 0, // Add this line
    width: '100%', // Add this line
    marginBottom: 150, 
  },
});

export default Generate;