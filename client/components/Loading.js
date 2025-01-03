import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  StyleSheet,
  ActivityIndicator,
  Animated,
} from "react-native";

const LoadingScreen = () => {
  const [quoteIndex, setQuoteIndex] = useState(Math.floor(Math.random() * 27));
  const [fadeAnim] = useState(new Animated.Value(0));

  const quotes = [
    "You're not a bad cook, you just have experimental taste buds",
    "Amazing things are about to happen",
    "Who let you cook?",
    "Greatness is just around the stove",
    "Good things come to those who eat",
    "Cook better than a regis boy",
    "Gordon Ramsay who??",
    "An empty stomach is not a good political adviser",
    "Tell me what you eat, and I will tell you who you are",
    "One cannot think well, love well, sleep well, if one has not dined well",
    "Ask not what you can do for your country. Ask what lunch is saying",
    "Food is our common ground, a universal experience",
    "Cooking is like love. It should be entered into with abandon or not at all",
    "The cure for the common breakfast",
    "Cooking is not just about ingredients, it's about weaving flavors into a story",
    "Anyone can cook, but only the fearless can be great",
    "In cooking, as in all of life, attitude is everything",
    "A messy kitchen is a sign of a happy cook",
    "My cooking skills are so unpredictable, I surprise even myself",
    "Breakfast, how about a scotch?",
    "In the short run, salt isnt everything, in the long run, its almost everything",
    "Risk comes from not knowing what you're doing",
    "In cooking, what is comfortable is rarely profitable",
    'The four most dangerous words in cooking are:" I don\'t need a recipe "',
    "The grocery store is filled with individuals who know the price of everything, but the flavor of nothing",
    "The biggest risk of all is not taking one with your salt",
    "How many Michelin-starred chefs do you know who became good by cooking only pre-packaged meals?",
    "Think outside the pot",
  ];

  useEffect(() => {
    const quoteInterval = setInterval(() => {
      setQuoteIndex(Math.floor(Math.random() * quotes.length));
      fadeIn();
    }, 5000);

    return () => {
      clearInterval(quoteInterval);
    };
  }, []);

  const fadeIn = () => {
    fadeAnim.setValue(0);
    Animated.timing(fadeAnim, {
      toValue: 1,
      duration: 500, // Increase the duration to 3000ms (3 seconds)
      useNativeDriver: true,
    }).start();
  };

  useEffect(() => {
    fadeIn();
  }, [quoteIndex]);

  return (
    <View style={styles.container}>
      <ActivityIndicator size="large" color="#00ff00" />
      <Animated.Text style={{ ...styles.quote, opacity: fadeAnim }}>
        {quotes[quoteIndex]}
      </Animated.Text>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
  },
  quote: {
    marginTop: 20,
    fontSize: 18,
    color: "lightgray",
    paddingHorizontal: 20,
    textAlign: "center",
  },
});

export default LoadingScreen;
