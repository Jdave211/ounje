import React, { useState, useEffect } from 'react';
import { View, Text, StyleSheet, ActivityIndicator } from 'react-native';

const LoadingScreen = () => {
  const [quoteIndex, setQuoteIndex] = useState(0);
  const [isLoading, setIsLoading] = useState(true); // For loading state
  const quotes = [
    "Patience is a virtue...",
    "Amazing things are about to happen...",
    "Who let you cook?...",
    "Greatness is just around the corner...",
    "Good things come to those who wait...",
    "Cook better than a regis boy...",
    "Ramsey Gordon who?...",
    "An empty stomach is not a good political adviser...",
    "Tell me what you eat, and I will tell you what you are...",
    "One cannot think well, love well, sleep well, if one has not dined well...",
    "Ask not what you can do for your country. Ask what's for lunch...",
    "Food is our common ground, a universal experience...",



    // Add more quotes here
  ];

  useEffect(() => {
    const quoteInterval = setInterval(() => {
      setQuoteIndex(Math.floor(Math.random() * quotes.length));
    }, 5000);

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
  }
});

export default LoadingScreen;
