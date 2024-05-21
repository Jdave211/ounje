import React from "react";
import { View, Text } from "react-native";
import CommunityCard from "../components/CommunityCard";

const Community = () => {
  return (
    <View style={styles.container}>
      <CommunityCard />
    </View>
  );
};

const styles = {
  container: {
    flex: 1,
    backgroundColor: "black",
  },
  text: {
    color: "white",
    fontSize: 20,
  },
};

export default Community;
