import React from 'react';
import { View, Text, ScrollView, Image, StyleSheet } from 'react-native';
import jrice from '../assets/jrice.png';
import bowl2 from '../assets/bowl2.png';
import pasta from '../assets/pasta.png';
import pancakes from '../assets/pancakes.png';
import silicon from '../assets/silicon.png';
import combination from '../assets/combination.png';
import toast from '../assets/toast.png';

const FoodRow = () => {
  const foods = [
    { id: 1, src: jrice },
    { id: 4, src: pasta },
    { id: 3, src: bowl2 },
    { id: 5, src: pancakes },
    { id: 6, src: silicon },
    { id: 2, src: toast },
    { id: 8, src: combination },

    // Add more food items here
  ];

  return (
    <ScrollView horizontal={true} showsHorizontalScrollIndicator={false}>
      {foods.map((food) => (
        <View key={food.id} style={styles.imageContainer}>
          <Image source={food.src} style={styles.image} resizeMode="contain" />
        </View>
      ))}
    </ScrollView>
  );
};

const styles = StyleSheet.create({
  imageContainer: {
    width: 150, // Adjust as needed
    marginRight: 4, // Adjust as needed
  },
  image: {
    width: '100%',
    height: 130, // Adjust as needed
  },
  text: {
    color: 'white',
    textAlign: 'center',
  },
});

export default FoodRow;