import React, { useState, useEffect } from "react";
import { View, Text, StyleSheet, TouchableOpacity } from "react-native";
import { useNavigation } from "@react-navigation/native";

// can import directories in the root directory now by using the @ symbol
// instead of using long relative paths like ../../components/FoodRow :)
// check out the babel.config.js file to see how this is configured
import FoodRow from "@components/FoodRow";
import ImageUploadForm from "@components/ImageUploadForm";
import Loading from "@components/Loading";

const Generate = () => {
  const [isLoading, setIsLoading] = useState(false);
  const navigation = useNavigation();

  const handleLoading = (loading) => {
    setIsLoading(loading);
  };

  useEffect(() => {
    if (!isLoading) {
      navigation.navigate("CheckIngredients");
    }
  }, [isLoading]);

  return (
    <View style={styles.container}>
      <Text style={styles.text}>"[Insert intro]"</Text>
      {__DEV__ && (
        <View>
          <Text style={styles.text}>This is a development environment</Text>
          <TouchableOpacity
            onPress={() => navigation.navigate("CheckIngredients")}
          >
            <Text style={styles.text}>Developement navigation</Text>
            <Text style={styles.text}>- Check Ingredients</Text>
          </TouchableOpacity>
        </View>
      )}
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
