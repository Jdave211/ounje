import React, { useEffect, useState } from 'react';
import { StyleSheet, Text, ActivityIndicator, Dimensions, TouchableOpacity, View } from 'react-native';
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
  const [error, setError] = useState(null);
  const [retryCount, setRetryCount] = useState(0);
  const MAX_RETRIES = 3;

  const fetchSingleRecipe = async () => {
    try {
      setLoading(true);
      setError(null);

      // Add timeout to the fetch request
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 10000); // 10 second timeout

      try {
        const response = await fetch(
          'https://www.themealdb.com/api/json/v1/1/random.php',
          { signal: controller.signal }
        );
        clearTimeout(timeoutId);

        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }

        const data = await response.json();

        if (data.meals && data.meals.length > 0) {
          setRecipe(data.meals[0]);
          setRetryCount(0); // Reset retry count on success
        } else {
          throw new Error('No recipe found in response');
        }
      } catch (fetchError) {
        if (fetchError.name === 'AbortError') {
          throw new Error('Request timed out. Please check your internet connection.');
        }
        throw fetchError;
      }
    } catch (error) {
      console.error('Error fetching single recipe:', error);
      setError(error.message);
      setRecipe(null);

      // Implement retry logic
      if (retryCount < MAX_RETRIES) {
        setRetryCount(prev => prev + 1);
        setTimeout(() => {
          fetchSingleRecipe();
        }, 1000 * (retryCount + 1)); // Exponential backoff
      }
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
        <View style={styles.loadingContainer}>
          <ActivityIndicator size="large" color="#38F096" />
          <Text style={styles.loadingText}>
            {retryCount > 0
              ? `Retrying... (Attempt ${retryCount}/${MAX_RETRIES})`
              : 'Finding your next delicious recipe...'}
          </Text>
        </View>
      </GestureHandlerRootView>
    );
  }

  // If there's an error, show error state with retry button
  if (!recipe && !loading && error) {
    return (
      <GestureHandlerRootView style={styles.container}>
        <View style={styles.errorContainer}>
          <Text style={styles.errorText}>{error}</Text>
          <TouchableOpacity
            style={styles.retryButton}
            onPress={() => {
              setRetryCount(0);
              fetchSingleRecipe();
            }}
          >
            <Text style={styles.retryButtonText}>Try Again</Text>
          </TouchableOpacity>
        </View>
      </GestureHandlerRootView>
    );
  }

  // If there's no recipe and we're not loading, show empty state
  if (!recipe && !loading) {
    return (
      <GestureHandlerRootView style={styles.container}>
        <View style={styles.emptyContainer}>
          <Text style={styles.noMoreText}>No recipes found</Text>
          <TouchableOpacity
            style={styles.retryButton}
            onPress={fetchSingleRecipe}
          >
            <Text style={styles.retryButtonText}>Find New Recipes</Text>
          </TouchableOpacity>
        </View>
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