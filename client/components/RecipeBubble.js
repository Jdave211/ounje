import React from "react";
import { TouchableOpacity, Text, StyleSheet } from "react-native";

const RecipeBubble = ({ word, onSelect }) => {
  return (
    <TouchableOpacity style={styles.bubble} onPress={() => onSelect(word)}>
      <Text style={styles.word}>{word}</Text>
    </TouchableOpacity>
  );
};

const styles = StyleSheet.create({
  bubble: {
    backgroundColor: "#add8e6", // Light blue bubble
    paddingVertical: 10,
    paddingHorizontal: 20,
    borderRadius: 20,
    margin: 10,
    alignItems: "center",
  },
  word: {
    fontSize: 18,
    color: "#000",
  },
});

export default RecipeBubble;
