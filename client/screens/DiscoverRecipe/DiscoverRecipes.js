import React, { useEffect, useState } from 'react';
import { StyleSheet, Text, ActivityIndicator, Dimensions } from 'react-native';
import {
  GestureHandlerRootView,
  PanGestureHandler,
} from 'react-native-gesture-handler';
import Animated, {
  useSharedValue,
  useAnimatedGestureHandler,
  useAnimatedStyle,
  withSpring,
  runOnJS,
} from 'react-native-reanimated';
import RecipeCard from '../../components/RecipeCard';

const { width, height } = Dimensions.get('window');

// Tweak these for how far/fast you must swipe for removal.
const SWIPE_THRESHOLD = width * 0.25;
const VELOCITY_THRESHOLD = 800;

const DiscoverRecipes = () => {
  // We'll store just ONE recipe at a time
  const [recipe, setRecipe] = useState(null);
  const [loading, setLoading] = useState(false);

  // Shared animated values for the current (and only) card
  const translateX = useSharedValue(0);
  const translateY = useSharedValue(0);
  const rotateZ = useSharedValue(0);

  useEffect(() => {
    // Fetch our first single recipe when the component mounts
    fetchSingleRecipe();
  }, []);

  // Fetch exactly one random recipe
  const fetchSingleRecipe = async () => {
    try {
      setLoading(true);
      const response = await fetch('https://www.themealdb.com/api/json/v1/1/random.php');
      const data = await response.json();

      if (data.meals && data.meals.length > 0) {
        setRecipe(data.meals[0]);
      } else {
        // If the API returns no valid meal, setRecipe(null) or handle error
        setRecipe(null);
      }
    } catch (error) {
      console.error('Error fetching single recipe:', error);
      setRecipe(null);
    } finally {
      setLoading(false);
    }
  };

  // Called after the card has fully swiped off-screen
  const onSwipeComplete = () => {
    // 1) Reset the card's animation values
    translateX.value = 0;
    translateY.value = 0;
    rotateZ.value = 0;

    // 2) Fetch a new random recipe to display
    runOnJS(fetchSingleRecipe)();
  };

  // Pan gesture handler for the single card
  const gestureHandler = useAnimatedGestureHandler({
    onStart: (_, context) => {
      context.startX = translateX.value;
      context.startY = translateY.value;
    },
    onActive: (event, context) => {
      translateX.value = context.startX + event.translationX;
      translateY.value = context.startY + event.translationY;
      // Slight rotation as we drag horizontally
      rotateZ.value = (translateX.value / width) * 15; // up to ~15 deg
    },
    onEnd: (event) => {
      const { velocityX } = event;
      if (
        Math.abs(translateX.value) > SWIPE_THRESHOLD ||
        Math.abs(velocityX) > VELOCITY_THRESHOLD
      ) {
        const toValue = translateX.value > 0 ? width * 1.5 : -width * 1.5;
        // Animate off the screen, then trigger onSwipeComplete
        translateX.value = withSpring(
          toValue,
          { velocity: velocityX },
          () => {
            runOnJS(onSwipeComplete)();
          }
        );
      } else {
        // Snap back if not swiped far enough
        translateX.value = withSpring(0);
        translateY.value = withSpring(0);
        rotateZ.value = withSpring(0);
      }
    },
  });

  // Animated style to reflect our translate & rotate on the card
  const animatedStyle = useAnimatedStyle(() => {
    return {
      transform: [
        { translateX: translateX.value },
        { translateY: translateY.value },
        { rotateZ: `${rotateZ.value}deg` },
      ],
    };
  });

  // If loading and we have no recipe to show yet
  if (loading && !recipe) {
    return (
      <GestureHandlerRootView style={styles.container}>
        <ActivityIndicator size="large" color="green" />
      </GestureHandlerRootView>
    );
  }

  // If there's no recipe and we're not loading, maybe show a message
  if (!recipe && !loading) {
    return (
      <GestureHandlerRootView style={styles.container}>
        <Text style={styles.noMoreText}>No recipe found</Text>
      </GestureHandlerRootView>
    );
  }

  // Otherwise, render our single swipeable card
  return (
    <GestureHandlerRootView style={styles.container}>
      <PanGestureHandler onGestureEvent={gestureHandler}>
        <Animated.View style={[styles.card, animatedStyle]}>
          <RecipeCard
            id={recipe.idMeal}
            title={recipe.strMeal}
            imageUrl={recipe.strMealThumb}
            readyInMinutes={recipe.strCookingTime || '15'}
          />
        </Animated.View>
      </PanGestureHandler>
    </GestureHandlerRootView>
  );
};

export default DiscoverRecipes;

const styles = StyleSheet.create({
  container: {
    width: '100%',     // fixed height in px
    alignItems: 'center',
    justifyContent: 'center',
  },
  card: {
    // Dynamic width & height; tweak if you want different ratio
    width: '80%',           // 80% of screen width
    height: '60%',          // 60% of screen height
    maxWidth: 400,          // Optional max
    maxHeight: 600,         // Optional max
    borderRadius: 16,
    // Center its content
    alignItems: 'center',
    justifyContent: 'center',
  },
  noMoreText: {
    color: '#fff',
    fontSize: 18,
  },
});