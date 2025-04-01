import React from "react";
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  ImageBackground,
} from "react-native";
import { useNavigation } from "@react-navigation/native";

const CaloriesPaywall = () => {
  const navigation = useNavigation();

  return (
    <View style={styles.container}>
      <ImageBackground
        source={require("../../assets/calories-page.jpeg")} // Change this to your actual background image
        style={styles.backgroundImage}
      >
          <View style={styles.content}>
            <Text style={styles.title}>Premium Feature</Text>
            <Text style={styles.message}>
              This feature is exclusively available for premium members.{" "}
              <Text style={{ fontWeight: "bold" }}>
                Upgrade now to enjoy unlimited access to calorie counting and
                more!
              </Text>
            </Text>
            <TouchableOpacity
              style={styles.button}
              onPress={() => navigation.navigate("PremiumSubscription")}
            >
              <Text style={styles.buttonText}>Go to Settings</Text>
            </TouchableOpacity>
          </View>
      </ImageBackground>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "#121212",
  },
  backgroundImage: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    width: "100%",
    height: "100%",
  },
  blurView: {
    ...StyleSheet.absoluteFillObject,
    justifyContent: "center",
    alignItems: "center",
  },
  content: {
    backgroundColor: "rgba(0, 0, 0, 0.6)",
    borderRadius: 10,
    padding: 20,
    alignItems: "center",
    marginHorizontal: 20,
  },
  title: {
    fontSize: 24,
    fontWeight: "bold",
    color: "#38F096",
    marginBottom: 10,
  },
  message: {
    color: "white",
    fontSize: 16,
    textAlign: "center",
    marginBottom: 20,
    lineHeight: 24,
  },
  button: {
    backgroundColor: "#38F096",
    borderRadius: 10,
    paddingVertical: 10,
    paddingHorizontal: 20,
    alignItems: "center",
  },
  buttonText: {
    color: "black",
    fontWeight: "bold",
    fontSize: 16,
  },
});

export default CaloriesPaywall;
