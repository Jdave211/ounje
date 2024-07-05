import React, { useState } from "react";
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  Image,
  ActivityIndicator,
  ActionSheetIOS,
  Modal,
  ScrollView,
} from "react-native";
import * as ImagePicker from "expo-image-picker";
import * as ImageManipulator from "expo-image-manipulator";
import { AntDesign, Feather } from "@expo/vector-icons";
import axios from "axios";
import useImageProcessing from "../hooks/useImageProcessing";
import { useAppStore } from "@stores/app-store";

const CountCalories = () => {
  const [image, setImage] = useState(null);
  const [mealName, setMealName] = useState(null);
  const [calories, setCalories] = useState(null);
  const [macros, setMacros] = useState(null);
  const [foodItems, setFoodItems] = useState([]);
  const [loading, setLoading] = useState(false);
  const [modalVisible, setModalVisible] = useState(false);
  const [calorieImages, setCalorieImages] = useState([]);
  const [calorieImageUris, setCalorieImageUris] = useState([]);
  const userId = useAppStore((state) => state.user_id);

  const { convertImageToBase64, storeCaloryImages } = useImageProcessing();

  const pickImage = async () => {
    const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync();
    if (status !== "granted") {
      alert("Sorry, we need camera roll permissions to make this work!");
      return;
    }

    let result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ImagePicker.MediaTypeOptions.All,
      allowsEditing: true,
      aspect: [4, 3],
      quality: 1,
    });

    if (!result.canceled) {
      const manipulatedImage = await manipulateImage(result.assets[0].uri);
      setImage(manipulatedImage.uri);
      resetAnalysisState();
      const uri = result.assets[0].uri;
      setCalorieImageUris((prevUris) => [...prevUris, uri]);
      const base64Image = await convertImageToBase64(uri);
      setCalorieImages((prevImages) => [...prevImages, base64Image]);
    }
  };

  const takePhoto = async () => {
    const { status } = await ImagePicker.requestCameraPermissionsAsync();
    if (status !== "granted") {
      alert("Sorry, we need camera permissions to make this work!");
      return;
    }

    let result = await ImagePicker.launchCameraAsync({
      allowsEditing: true,
      aspect: [4, 3],
      quality: 1,
    });

    if (!result.canceled) {
      const manipulatedImage = await manipulateImage(result.assets[0].uri);
      setImage(manipulatedImage.uri);
      resetAnalysisState();
      const uri = result.assets[0].uri;
      setCalorieImageUris((prevUris) => [...prevUris, uri]);
      const base64Image = await convertImageToBase64(uri);
      setCalorieImages((prevImages) => [...prevImages, base64Image]);
    }
  };

  const manipulateImage = async (uri) => {
    const actions = [{ resize: { width: 800 } }];
    const saveOptions = {
      compress: 0.8,
      format: ImageManipulator.SaveFormat.JPEG,
      base64: false,
    };

    const manipulatedImage = await ImageManipulator.manipulateAsync(
      uri,
      actions,
      saveOptions
    );
    return manipulatedImage;
  };

  const showActionSheet = () => {
    ActionSheetIOS.showActionSheetWithOptions(
      {
        options: ["Cancel", "Take Photo", "Choose from Library"],
        cancelButtonIndex: 0,
      },
      (buttonIndex) => {
        if (buttonIndex === 1) {
          takePhoto();
        } else if (buttonIndex === 2) {
          pickImage();
        }
      }
    );
  };

  const resetAnalysisState = () => {
    setMealName(null);
    setCalories(null);
    setMacros(null);
    setFoodItems([]);
  };

  const analyzeImage = async () => {
    if (!image) {
      alert("Please upload an image first!");
      return;
    }
    setLoading(true);

    try {
      const formData = new FormData();
      formData.append("image", {
        uri: image,
        type: "image/jpeg",
        name: "image.jpg",
      });

      const response = await axios.post(
        "https://vision.foodvisor.io/api/1.0/en/analysis/",
        formData,
        {
          headers: {
            Authorization: "Api-Key Ykg5QjJS.mj5OnDHC5QLQoMmkzLBgX0GYRyknzLi1",
            "Content-Type": "multipart/form-data",
          },
        }
      );

      if (response.status === 200) {
        const data = response.data;

        let allMealNames = data.items.map(
          (item) => item.food[0].food_info.display_name
        );
        setMealName(allMealNames.join(", ") || "Unknown Meal");

        let totalCalories = 0;
        let totalMacros = {
          fat: 0,
          proteins: 0,
          carbs: 0,
          fibers: 0,
          sugars: 0,
        };

        const calculateNutrients = (foodItem, multiplier = 1) => {
          const quantity = foodItem.quantity;
          const nutrition = foodItem.food_info.nutrition;

          const calories =
            nutrition.calories_100g * (quantity / 100) * multiplier;
          const fat = nutrition.fat_100g * (quantity / 100) * multiplier;
          const proteins =
            nutrition.proteins_100g * (quantity / 100) * multiplier;
          const carbs = nutrition.carbs_100g * (quantity / 100) * multiplier;
          const fibers = nutrition.fibers_100g * (quantity / 100) * multiplier;
          const sugars = nutrition.sugars_100g * (quantity / 100) * multiplier;

          totalCalories += calories;
          totalMacros.fat += fat;
          totalMacros.proteins += proteins;
          totalMacros.carbs += carbs;
          totalMacros.fibers += fibers;
          totalMacros.sugars += sugars;

          if (foodItem.ingredients && foodItem.ingredients.length > 0) {
            foodItem.ingredients.forEach((ingredient) =>
              calculateNutrients(ingredient, multiplier)
            );
          }
        };

        const foodItemsData = data.items.map((item) => {
          const mostAccurateFood = item.food[0];
          calculateNutrients(mostAccurateFood);
          return {
            topChoice: mostAccurateFood,
            alternatives: item.food.slice(1, 4),
          };
        });

        setFoodItems(foodItemsData);

        setCalories(totalCalories.toFixed(0));
        setMacros({
          fat: totalMacros.fat.toFixed(2),
          proteins: totalMacros.proteins.toFixed(2),
          carbs: totalMacros.carbs.toFixed(2),
          fibers: totalMacros.fibers.toFixed(2),
          sugars: totalMacros.sugars.toFixed(2),
        });

        if (calorieImages.length > 0) {
          await storeCaloryImages(userId, calorieImages);
        }

        setModalVisible(true);
      } else {
        console.error("API call failed with status: ", response.status);
        alert("Failed to analyze the image");
      }
    } catch (error) {
      console.error("API call error: ", error);
      alert("An error occurred while analyzing the image");
    } finally {
      setLoading(false);
    }
  };

  const clearImage = () => {
    setImage(null);
    resetAnalysisState();
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Calorie Counter</Text>
      <Text style={styles.instructions}>
        Take a picture of your meal, then click on Analyze to count the
        calories!
      </Text>
      <Text style={styles.warning}>
        Please make sure the food items are accurately centered in the picture.
      </Text>
      <View style={styles.imageContainer}>
        {image ? (
          <Image source={{ uri: image }} style={styles.image} />
        ) : (
          <TouchableOpacity
            style={styles.uploadButton}
            onPress={showActionSheet}
          >
            <AntDesign name="camerao" size={40} color="white" />
            <Text style={styles.uploadText}>Upload or Take Photo</Text>
          </TouchableOpacity>
        )}
        {image && (
          <TouchableOpacity style={styles.removeButton} onPress={clearImage}>
            <Feather name="trash-2" size={24} color="white" />
          </TouchableOpacity>
        )}
      </View>
      <View style={styles.analyzeButtonContainer}>
        {loading ? (
          <ActivityIndicator size="large" color="#38F096" />
        ) : (
          <TouchableOpacity style={styles.analyzeButton} onPress={analyzeImage}>
            <Text style={styles.analyzeButtonText}>Analyze Calories</Text>
          </TouchableOpacity>
        )}
      </View>
      <Modal
        animationType="slide"
        transparent={true}
        visible={modalVisible}
        onRequestClose={() => setModalVisible(false)}
      >
        <View style={styles.modalContainer}>
          <View style={styles.modalContent}>
            <TouchableOpacity
              style={styles.closeIcon}
              onPress={() => setModalVisible(false)}
            >
              <AntDesign name="close" size={24} color="white" />
            </TouchableOpacity>
            <Text style={styles.modalTitle}>Your Calories</Text>
            <View style={styles.totalContainer}>
              <Text style={styles.totalCalories}>{calories} Cal</Text>
              {macros && (
                <View style={styles.macrosContainer}>
                  <View style={styles.macroRow}>
                    <Text style={styles.macroLabel}>Proteins:</Text>
                    <Text style={styles.macroValue}>{macros.proteins} g</Text>
                  </View>
                  <View style={styles.macroRow}>
                    <Text style={styles.macroLabel}>Fat:</Text>
                    <Text style={styles.macroValue}>{macros.fat} g</Text>
                  </View>
                  <View style={styles.macroRow}>
                    <Text style={styles.macroLabel}>Carbs:</Text>
                    <Text style={styles.macroValue}>{macros.carbs} g</Text>
                  </View>
                  <View style={styles.macroRow}>
                    <Text style={styles.macroLabel}>Fibers:</Text>
                    <Text style={styles.macroValue}>{macros.fibers} g</Text>
                  </View>
                  <View style={styles.macroRow}>
                    <Text style={styles.macroLabel}>Sugars:</Text>
                    <Text style={styles.macroValue}>{macros.sugars} g</Text>
                  </View>
                </View>
              )}
            </View>
            <ScrollView style={styles.modalScroll}>
              <View style={styles.foodItemsContainer}>
                {foodItems.map((item, index) => (
                  <View key={index} style={styles.foodItem}>
                    <Text style={styles.foodName}>
                      {item.topChoice.food_info.display_name}
                    </Text>
                    <Text style={styles.foodCalories}>
                      {(
                        item.topChoice.food_info.nutrition.calories_100g *
                        (item.topChoice.quantity / 100)
                      ).toFixed(0)}{" "}
                      Cal
                    </Text>
                    <Text style={styles.foodQuantity}>
                      {item.topChoice.quantity}g
                    </Text>
                    <Text style={styles.alternativesHeader}>or</Text>
                    {item.alternatives.map((alt, altIndex) => (
                      <Text key={altIndex} style={styles.alternative}>
                        {alt.food_info.display_name}
                      </Text>
                    ))}
                  </View>
                ))}
              </View>
            </ScrollView>
            <Text style={styles.disclaimer}>
              The information provided may not be 100% accurate. We recommend
              using it as a helpful guide and applying your best judgment.
            </Text>
          </View>
        </View>
      </Modal>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#121212",
    padding: 20,
    justifyContent: "center",
    alignItems: "center",
  },
  title: {
    fontSize: 24,
    fontWeight: "bold",
    color: "white",
    position: "absolute",
    top: 70,
    textAlign: "center",
    width: "100%",
  },
  instructions: {
    color: "white",
    marginBottom: 50,
    fontWeight: "bold",
    fontSize: 17,
  },
  warning: {
    color: "gray",
    fontSize: 15,
    textAlign: "center",
    marginBottom: 20,
  },
  imageContainer: {
    width: 300,
    height: 300,
    borderRadius: 10,
    borderColor: "white",
    borderWidth: 2,
    justifyContent: "center",
    alignItems: "center",
    marginBottom: 20,
    backgroundColor: "#121212",
    position: "relative",
  },
  image: {
    width: "100%",
    height: "100%",
    borderRadius: 10,
  },
  uploadButton: {
    justifyContent: "center",
    alignItems: "center",
  },
  uploadText: {
    color: "white",
    fontSize: 16,
  },
  analyzeButtonContainer: {
    width: "80%",
    alignItems: "center",
    marginTop: 30,
    padding: 10,
  },
  analyzeButton: {},
  analyzeButtonText: {
    color: "#38F096",
    fontSize: 18,
    fontWeight: "bold",
  },
  modalContainer: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "rgba(0, 0, 0, 0.5)",
  },
  modalContent: {
    width: "90%",
    height: "78%",
    backgroundColor: "#121212",
    padding: 20,
    borderRadius: 20,
    position: "relative",
  },
  closeIcon: {
    position: "absolute",
    top: 10,
    right: 10,
  },
  modalTitle: {
    fontSize: 24,
    fontWeight: "bold",
    color: "white",
    marginBottom: 10,
    textAlign: "center",
  },
  modalScroll: {
    flex: 1,
  },
  foodItemsContainer: {
    paddingBottom: 10,
  },
  foodItem: {
    marginBottom: 20,
    borderBottomWidth: 1,
    borderBottomColor: "gray",
    paddingBottom: 10,
  },
  foodName: {
    fontSize: 18,
    color: "white",
    fontWeight: "bold",
  },
  foodCalories: {
    fontSize: 16,
    color: "#38F096",
  },
  foodQuantity: {
    fontSize: 14,
    color: "gray",
  },
  alternativesHeader: {
    fontSize: 12,
    color: "gray",
    marginVertical: 5,
  },
  alternative: {
    fontSize: 14,
    color: "lightgray",
  },
  totalContainer: {
    alignItems: "center",
    marginBottom: 10,
  },
  totalCalories: {
    fontSize: 24,
    fontWeight: "bold",
    color: "#38F096",
  },
  macrosContainer: {
    flexDirection: "column",
    width: "100%",
    alignItems: "center",
  },
  macroRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    width: "80%",
    marginBottom: 5,
  },
  macroLabel: {
    fontSize: 16,
    color: "white",
  },
  macroValue: {
    fontSize: 16,
    color: "white",
    textAlign: "right",
  },
  disclaimer: {
    color: "gray",
    fontSize: 14,
    textAlign: "center",
    marginTop: 10,
  },
  removeButton: {
    position: "absolute",
    top: 10,
    right: 10,
    backgroundColor: "rgba(0, 0, 0, 0.5)",
    borderRadius: 50,
    padding: 5,
  },
});

export default CountCalories;
