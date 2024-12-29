import React from 'react';
import { StyleSheet, Dimensions } from 'react-native';
import { PanGestureHandler } from 'react-native-gesture-handler';
import Animated, { useAnimatedStyle } from 'react-native-reanimated';
import RecipeCard from '../../components/RecipeCard.js';

const { width, height } = Dimensions.get('window');

const SwipeableCard = ({
  item,
  index,
  isTopCard,
  translateX,
  translateY,
  rotateZ,
  gestureHandler,
  recipesLength,
}) => {
  const position = index;

  const animatedCardStyle = useAnimatedStyle(() => {
    const scale = 1 - position * 0.05;
    const translateYPosition = -position * 10;

    return {
      transform: [
        { translateY: translateYPosition },
        { scale },
        ...(isTopCard
          ? [
              { translateX: translateX.value },
              { translateY: translateY.value },
              { rotateZ: `${rotateZ.value}deg` },
            ]
          : []),
      ],
    };
  });

  return (
    <Animated.View
      style={[
        styles.cardContainer,
        animatedCardStyle,
        { zIndex: recipesLength - index },
      ]}
    >
      {isTopCard ? (
        <PanGestureHandler onGestureEvent={gestureHandler}>
          <Animated.View style={styles.cardInnerContainer}>
            <RecipeCard
              id={item.idMeal}
              title={item.strMeal}
              imageUrl={item.strMealThumb}
              readyInMinutes={
                item.readyInMinutes ||
                (item.strCookingTime ? parseInt(item.strCookingTime) : 30)
              }
            />
          </Animated.View>
        </PanGestureHandler>
      ) : (
        <Animated.View style={styles.cardInnerContainer}>
          <RecipeCard
            id={item.idMeal}
            title={item.strMeal}
            imageUrl={item.strMealThumb}
            readyInMinutes={
              item.readyInMinutes ||
              (item.strCookingTime ? parseInt(item.strCookingTime) : 10)
            }
          />
        </Animated.View>
      )}
    </Animated.View>
  );
};

export default SwipeableCard;

const styles = StyleSheet.create({
  cardContainer: {
    position: 'absolute',
    width: width * 0.9, // Set width to 90% of the screen width
    height: height * 0.6, // Adjust height as needed
    justifyContent: 'center',
    alignItems: 'center',
  },
  cardInnerContainer: {
    flex: 1,
    width: '100%',
    height: '100%',
  },
});
