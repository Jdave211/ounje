// DiscoverRecipes.js

import React, { useEffect, useState } from 'react';
import {
  StyleSheet,
  ActivityIndicator,
  Dimensions,
  Text,
} from 'react-native';
import {
  PanGestureHandler,
  GestureHandlerRootView,
} from 'react-native-gesture-handler';
import Animated, {
  useSharedValue,
  useAnimatedGestureHandler,
  withSpring,
  runOnJS,
} from 'react-native-reanimated';
import SwipeableCard from './SwipeableCard';

const { width } = Dimensions.get('window');

const DiscoverRecipes = () => {
  const [recipes, setRecipes] = useState([]);
  const [loading, setLoading] = useState(false);
  const [fetchCount, setFetchCount] = useState(0);
  const [currentIndex, setCurrentIndex] = useState(0);

  // Shared values for animation
  const translateX = useSharedValue(0);
  const translateY = useSharedValue(0);
  const rotateZ = useSharedValue(0);

  useEffect(() => {
    fetchRandomRecipes(5); // Fetch initial 10 recipes
  }, []);

  const fetchRandomRecipes = async (count = 1) => {
    try {
      setLoading(true);
      const newRecipes = [];

      for (let i = 0; i < count; ) {
        const response = await fetch(
          'https://www.themealdb.com/api/json/v1/1/random.php'
        );
        const data = await response.json();

        const newRecipe = data.meals[0];

        // Use functional update to get the latest state
        setRecipes((prevRecipes) => {
          const recipeExists = prevRecipes.some(
            (recipe) => recipe.idMeal === newRecipe.idMeal
          );

          if (!recipeExists) {
            newRecipes.push({
              ...newRecipe,
              uniqueKey: `${newRecipe.idMeal}-${fetchCount}-${i}`,
            });
            setFetchCount((prevCount) => prevCount + 1);
            i++; // Only increment if we added a new recipe
          }
          return prevRecipes;
        });
      }

      setRecipes((prevRecipes) => [...prevRecipes, ...newRecipes]);
    } catch (error) {
      console.error('Error fetching recipes:', error);
    } finally {
      setLoading(false);
    }
  };

  const maxVisibleItems = 10;

  const onSwipeComplete = () => {
    setCurrentIndex((prevIndex) => {
      const newIndex = prevIndex + 1;

      // Fetch more recipes if needed
      if (recipes.length - newIndex <= maxVisibleItems * 2) {
        fetchRandomRecipes(5);
      }

      return newIndex;
    });

    // Reset animation values
    translateX.value = 0;
    translateY.value = 0;
    rotateZ.value = 0;
  };

  const gestureHandler = useAnimatedGestureHandler({
    onStart: (_, context) => {
      context.startX = translateX.value;
      context.startY = translateY.value;
    },
    onActive: (event, context) => {
      translateX.value = context.startX + event.translationX;
      translateY.value = context.startY + event.translationY;
      rotateZ.value = (translateX.value / width) * 15; // Adjust rotation angle
    },
    onEnd: (event) => {
      const swipeThreshold = width * 0.25;
      const velocityThreshold = 800;

      if (
        Math.abs(translateX.value) > swipeThreshold ||
        Math.abs(event.velocityX) > velocityThreshold
      ) {
        const toValue = translateX.value > 0 ? width * 1.5 : -width * 1.5;
        translateX.value = withSpring(
          toValue,
          { velocity: event.velocityX },
          () => {
            runOnJS(onSwipeComplete)();
          }
        );
      } else {
        translateX.value = withSpring(0);
        translateY.value = withSpring(0);
        rotateZ.value = withSpring(0);
      }
    },
  });

  return (
    <GestureHandlerRootView style={styles.container}>
      {recipes.length > currentIndex ? (
        recipes
          .slice(currentIndex, currentIndex + maxVisibleItems)
          .reverse()
          .map((item, index) => (
            <SwipeableCard
              key={item.uniqueKey}
              item={item}
              index={index}
              isTopCard={index === 0}
              translateX={translateX}
              translateY={translateY}
              rotateZ={rotateZ}
              gestureHandler={gestureHandler}
              recipesLength={recipes.length}
            />
          ))
      ) : loading ? (
        <ActivityIndicator size="large" color="green" />
      ) : (
        <Text>No more recipes</Text>
      )}
    </GestureHandlerRootView>
  );
};

export default DiscoverRecipes;

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    paddingTop: 450, // Adjust as needed
  },
});
