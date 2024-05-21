import React from "react";
import { View, Text } from "react-native";

const Community = () => {
  return (
    <View style={styles.container}>
      <Text style={styles.text}>Community</Text>
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
