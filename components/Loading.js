import React, { useState, useEffect } from 'react';
import { View, Text, StyleSheet, ActivityIndicator } from 'react-native';

const LoadingScreen = () => {
  const [quoteIndex, setQuoteIndex] = useState(0);
  const [isLoading, setIsLoading] = useState(true); // For loading state
  const quotes = [
    "You're not a bad cook, you just have experimental taste buds.",
    "Amazing things are about to happen...",
    "Who let you cook?...",
    "Greatness is just around the corner...",
    "Good things come to those who wait...",
    "Cook better than a regis boy...",
    "Gordon Ramsay who??...",
    "An empty stomach is not a good political adviser...",
    "Tell me what you eat, and I will tell you who you are...",
    "One cannot think well, love well, sleep well, if one has not dined well...",
    "Ask not what you can do for your country. Ask what's for lunch...",
    "Food is our common ground, a universal experience...",
    "Cooking is like love. It should be entered into with abandon or not at all...",
    "The key to the common breakfast",
    "Cooking is not just about ingredients, it's about weaving flavors into a story.",
    "Anyone can cook, but only the fearless can be great.",
    "In cooking, as in all of life, attitude is everything.",
    "A messy kitchen is a sign of a happy cook.",
  ];

  useEffect(() => {
    const quoteInterval = setInterval(() => {
      setQuoteIndex(Math.floor(Math.random() * quotes.length));
    }, 7000);

    // Simulate loading progress
    const progressInterval = setInterval(() => {
      // Replace with your actual loading logic
      if (Math.random() > 0.95) { // Simulating completion
        setIsLoading(false);
        clearInterval(progressInterval);
      }
    }, 500);

    return () => {
      clearInterval(quoteInterval);
      clearInterval(progressInterval);
    };
  }, []);

  return (
    <View style={styles.container}>
      <ActivityIndicator size="large" color="green" /> 
      <Text style={styles.quote}>
        {quotes[quoteIndex]}
      </Text>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  quote: {
    marginTop: 20,
    fontSize: 18,
    color: 'white',
    width: '80%', // This will make the text take up 80% of the screen width
    padding: 10, // This will add some space around the text
    textAlign: 'center',
  }
});

export default LoadingScreen;
