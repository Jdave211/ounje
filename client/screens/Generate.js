import React, { useState, useEffect } from "react";
import { View, Text, StyleSheet } from "react-native";
import FoodRow from "../components/FoodRow";
import ImageUploadForm from "../components/ImageUploadForm";
import Loading from "../components/Loading";
import { useNavigation } from "@react-navigation/native";
import Inventory from "./Inventory";

const Generate = () => {
  const [isLoading, setIsLoading] = useState(false);
  const navigation = useNavigation();

  const handleLoading = (loading) => {
    setIsLoading(loading);
  };

  useEffect(() => {
    if (!isLoading) {
      navigation.navigate("Inventory");
    }
  }, [isLoading]);

  return (
    <View style={styles.container}>
      <Text style={styles.text}></Text>
      <View style={styles.foodRowContainer}>
        <FoodRow />
      </View>
      {isLoading ? <Loading /> : <ImageUploadForm onLoading={handleLoading} />}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "black",
  },
  text: {
    color: "white",
  },
  foodRowContainer: {
    width: "100%",
    marginTop: 70,
  },
});

export default Generate;
