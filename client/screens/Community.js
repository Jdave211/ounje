import React from "react";
import { View, Text } from "react-native";
import CheckIngredients from "../components/CheckIngredients";

const Community = () => {
  return (
    <View style={styles.container}>
      <CheckIngredients />
    </View>
  );
};

const styles = {
  container: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "black",
  },
  text: {
    color: "white",
    fontSize: 20,
  },
};

export default Community;
