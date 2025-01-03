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
  Dimensions,
  Platform,
} from "react-native";
import * as ImagePicker from "expo-image-picker";
import * as ImageManipulator from "expo-image-manipulator";
import { AntDesign, Feather } from "@expo/vector-icons";
import axios from "axios";
import useImageProcessing from "../../hooks/useImageProcessing";
import { useAppStore } from "../../stores/app-store";
import Paywall from "./CaloriesPaywall"; // Importing the Paywall component

const screenWidth = Dimensions.get("window").width;
const screenHeight = Dimensions.get("window").height;

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
  const [selectedTab, setSelectedTab] = useState("Analyze Calories");
  const userId = useAppStore((state) => state.user_id);
  const isPremium = true; // For testing purposes
  const isGuest = userId && userId.startsWith("guest");

  const { convertImageToBase64, storeCaloryImages } = useImageProcessing();

  if (!isPremium) {
    return <Paywall />;
  }

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

        if (!isGuest && calorieImages.length > 0) {
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
      <View style={styles.header}>
        <Text style={styles.headerText}>Calorie Counter</Text>
        <Text style={styles.headerSubtext}>
          Analyze your meals and view calorie history
        </Text>
      </View>

      <View style={styles.segmentedControl}>
        <TouchableOpacity
          style={[
            styles.segmentButton,
            selectedTab === "Analyze Calories" && styles.segmentButtonSelected,
          ]}
          onPress={() => setSelectedTab("Analyze Calories")}
        >
          <Text
            style={[
              styles.segmentButtonText,
              selectedTab === "Analyze Calories" &&
                styles.segmentButtonTextSelected,
            ]}
          >
            Analyze Calories
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[
            styles.segmentButton,
            selectedTab === "Calories History" && styles.segmentButtonSelected,
          ]}
          onPress={() => setSelectedTab("Calories History")}
        >
          <Text
            style={[
              styles.segmentButtonText,
              selectedTab === "Calories History" &&
                styles.segmentButtonTextSelected,
            ]}
          >
            Calories History
          </Text>
        </TouchableOpacity>
      </View>
      <ScrollView contentContainerStyle={styles.scrollContainer}>
        {selectedTab === "Analyze Calories" ? (
          <View style={styles.content}>
            <View style={styles.imageContainer}>
              {image ? (
                <Image source={{ uri: image }} style={styles.image} />
              ) : (
                <TouchableOpacity
                  style={styles.uploadButton}
                  onPress={() => {
                    Platform.OS === "ios" ? showActionSheet() : pickImage();
                  }}
                >
                  <AntDesign name="camerao" size={40} color="white" />
                  <Text style={styles.uploadText}>Upload or Take Photo</Text>
                </TouchableOpacity>
              )}
              {image && (
                <TouchableOpacity
                  style={styles.removeButton}
                  onPress={clearImage}
                >
                  <Feather name="trash-2" size={24} color="white" />
                </TouchableOpacity>
              )}
            </View>
            <View style={styles.calorieInstructions}>
              <Text style={styles.instructionsText}>
                Take a photo of your meal or upload an image to analyze the
                calories.
              </Text>
            </View>
            <View style={styles.analyzeButtonContainer}>
              {loading ? (
                <ActivityIndicator size="large" color="#38F096" />
              ) : (
                <TouchableOpacity
                  style={styles.analyzeButton}
                  onPress={analyzeImage}
                >
                  <Text style={styles.analyzeButtonText}>Analyze Calories</Text>
                </TouchableOpacity>
              )}
            </View>
          </View>
        ) : (
          <View style={styles.discoverCard}>
            <Text style={styles.discoverCardTitle}>Calories History</Text>
            <Text style={styles.warning}>
              Analyze calories to view and manage your history!
            </Text>
          </View>
        )}

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
      </ScrollView>
    </View>
  );
};

const styles = StyleSheet.create({
  scrollContainer: {
    flexGrow: 1,
  },
  container: {
    padding: Dimensions.get("window").width * 0.03,
    backgroundColor: "#121212",
    flexGrow: 1,
  },
  header: {
    justifyContent: "flex-start",
    alignItems: "flex-start",
    marginBottom: Dimensions.get("window").height * 0.05,
    marginTop: Dimensions.get("window").height * 0.1,
    marginLeft: Dimensions.get("window").width * 0.03,
  },
  headerText: {
    color: "#fff",
    fontSize: 25,
    fontWeight: "bold",
  },
  headerSubtext: {
    color: "gray",
    fontSize: screenWidth * 0.04,
    marginTop: 5,
  },
  segmentedControl: {
    flexDirection: "row",
    alignSelf: "stretch",
    marginBottom: 20,
    borderBottomWidth: 1,
    borderBottomColor: "#282C35",
  },
  segmentButton: {
    flex: 1,
    paddingVertical: 10,
    alignItems: "center",
  },
  segmentButtonSelected: {
    borderBottomWidth: 2,
    borderBottomColor: "gray",
  },
  segmentButtonText: {
    color: "gray",
    fontSize: 16,
  },
  segmentButtonTextSelected: {
    color: "white",
    fontWeight: "bold",
  },
  content: {
    flex: 1,
    alignItems: "center",
  },
  imageContainer: {
    width: screenWidth * 0.8,
    height: screenWidth * 0.5,
    borderRadius: 15,
    borderColor: "gray",
    borderWidth: 1,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "#1f1f1f",
    marginBottom: screenHeight * 0.03,
    position: "relative",
  },
  image: {
    width: "100%",
    height: "100%",
    borderRadius: 15,
  },
  calorieInstructions: {},
  instructionsText: {
    color: "gray",
  },
  uploadButton: {
    justifyContent: "center",
    alignItems: "center",
    paddingVertical: screenHeight * 0.02,
  },
  uploadText: {
    color: "white",
    fontSize: screenWidth * 0.04,
    marginTop: screenHeight * 0.01,
  },
  analyzeButtonContainer: {
    width: "80%",
    alignItems: "center",
    marginTop: screenHeight * 0.03,
  },
  analyzeButton: {
    backgroundColor: "#38F096",
    borderRadius: 10,
    paddingVertical: screenHeight * 0.015,
    paddingHorizontal: screenWidth * 0.1,
  },
  analyzeButtonText: {
    color: "#121212",
    fontSize: screenWidth * 0.045,
    fontWeight: "bold",
  },
  modalContainer: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "rgba(0, 0, 0, 0.7)",
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
    fontSize: screenWidth * 0.07,
    fontWeight: "bold",
    color: "white",
    marginBottom: screenHeight * 0.02,
    textAlign: "center",
  },
  modalScroll: {
    flex: 1,
  },
  discoverCard: {
    backgroundColor: "#1f1f1f",
    borderRadius: 10,
    padding: 20,
    marginBottom: 20,
  },
  discoverCardTitle: {
    color: "#fff",
    fontSize: screenWidth * 0.045, // Responsive font size
    fontWeight: "bold",
    marginBottom: 10,
  },
  warning: {
    color: "gray",
    fontSize: screenWidth * 0.04,
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
    fontSize: screenWidth * 0.045,
    color: "white",
    fontWeight: "bold",
  },
  foodCalories: {
    fontSize: screenWidth * 0.04,
    color: "#38F096",
  },
  foodQuantity: {
    fontSize: screenWidth * 0.035,
    color: "gray",
  },
  alternativesHeader: {
    fontSize: screenWidth * 0.03,
    color: "gray",
    marginVertical: 5,
  },
  alternative: {
    fontSize: screenWidth * 0.035,
    color: "lightgray",
  },
  totalContainer: {
    alignItems: "center",
    marginBottom: 10,
  },
  totalCalories: {
    fontSize: screenWidth * 0.07,
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
    fontSize: screenWidth * 0.04,
    color: "white",
  },
  macroValue: {
    fontSize: screenWidth * 0.04,
    color: "white",
    textAlign: "right",
  },
  disclaimer: {
    color: "gray",
    fontSize: screenWidth * 0.035,
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
