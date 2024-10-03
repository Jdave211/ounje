import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  StyleSheet,
  TouchableOpacity,
  ImageBackground,
  Alert,
  ScrollView,
  Dimensions,
} from "react-native";
import { useNavigation } from "@react-navigation/native";
import { SelectList } from "react-native-dropdown-select-list";
import { FontAwesome5 } from "@expo/vector-icons";
import GenerateRecipes from "../../components/GenerateRecipes"; // Ensure the correct import path
import Loading from "../../components/Loading"; // Ensure the correct import path
import RecipeBubble from "../../components/RecipeBubble"; // Ensure the correct import path
import generate_bg from "../../assets/generate_bg.jpg";
import { supabase, fetchUserProfile } from "../../utils/supabase";
import { useQuery } from "react-query";
import { useAppStore } from "../../stores/app-store";
import { useRecipeOptionsStore } from "../../stores/recipe-options-store";

export default function Generate() {
  const [isLoading, setIsLoading] = useState(false);
  const [recipes, setRecipes] = useState([]);
  const navigation = useNavigation();

  const setDishTypes = useRecipeOptionsStore((state) => state.setDishTypes);
  const flavors = ["Breakfast", "Lunch", "Dinner", "Snack"];
  const calorieRanges = [
    "<200 kcal",
    "200-500 kcal",
    "500-800 kcal",
    ">800kcal",
  ];
  const timeRanges = ["<15 min", "15-30 min", "30-60 min", ">60 min"];

  const handleLoading = (loading) => {
    setIsLoading(loading);
  };

  const userId = useAppStore((state) => state.user_id);

  const { data: profileData, error: profileError } = useQuery(
    ["profileData", userId],
    async () => {
      if (userId && !userId.startsWith("guest")) {
        let profile = await fetchUserProfile(userId);
        return profile;
      }
    },
    {
      enabled: !!userId && !userId.startsWith("guest"), // Only run the query if user_id is not null and does not start with "guest"
    }
  );

  const name =
    useMemo(() => profileData?.name?.split(" ")[0], [profileData]) ?? "there";

  console.log({ userId, profileData, name, profileError });

  if (profileError) {
    Alert.alert("Error fetching profile", profileError.message);
  }

  return (
    <ImageBackground source={generate_bg} style={styles.backgroundImage}>
      <View style={styles.overlay}>
        <View style={styles.header}>
          <View style={styles.headerTop}>
            <Text style={[styles.text, styles.name]}>Hi {name}</Text>
          </View>
          <Text style={styles.text}>
            Select your preferences, and get to cooking...
          </Text>
        </View>
        <View style={styles.content}>
          {isLoading ? (
            <Loading />
          ) : (
            <>
              <SelectList
                setSelected={(dish_type) => {
                  if (
                    isNaN(Number(dish_type)) &&
                    typeof dish_type === "string"
                  ) {
                    setDishTypes([dish_type]);
                  }
                }}
                data={flavors}
                placeholder="Select a flavor"
                placeholderStyles={{
                  color: "white",
                  fontSize: 20,
                  fontWeight: "bold",
                }}
                inputStyles={{ color: "white", fontWeight: "bold" }}
                selectedTextStyle={styles.selectedTextStyle}
                dropdownTextStyles={{ color: "white", fontWeight: "bold" }}
                save="value"
                maxHeight={900}
                arrowicon={
                  <FontAwesome5 name="chevron-down" size={12} color={"white"} />
                }
                search={false}
                boxStyles={{
                  marginTop: 10,
                  marginBottom: 10,
                  borderColor: "white",
                }}
                defaultOption={{
                  key: "1",
                  value: "What type of meal are you interested in?",
                }}
              />
              <View style={{ flex: 0.3 }}>
                <GenerateRecipes
                  onLoading={handleLoading}
                  onRecipesGenerated={setRecipes}
                />
                <View style={{ padding: 10 }}>
                  {recipes.map((recipe, index) => (
                    <View key={index}>
                      <Text style={{ color: "white" }}>
                        {JSON.stringify(recipe)}
                      </Text>
                    </View>
                  ))}
                </View>
              </View>
            </>
          )}
        </View>
      </View>
    </ImageBackground>
  );
}

const styles = StyleSheet.create({
  backgroundImage: {
    flex: 1,
    resizeMode: "cover",
  },
  overlay: {
    flex: 1,
    justifyContent: "flex-end",
  },
  header: {
    height: "40%",
    alignItems: "flex-start",
    justifyContent: "center",
    paddingHorizontal: 10,
    borderBottomLeftRadius: 10,
    borderBottomRightRadius: 10,
  },
  headerTop: {
    width: "100%",
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
  },
  name: {
    fontSize: 25,
    fontWeight: "bold",
  },
  talkButton: {
    backgroundColor: "#f08a5d",
    paddingVertical: 5,
    paddingHorizontal: 15,
    borderRadius: 20,
  },
  talkButtonText: {
    color: "white",
    fontSize: 16,
    fontWeight: "bold",
  },
  text: {
    color: "white",
    fontSize: 20,
    fontWeight: "bold",
  },
  content: {
    height: "60%",
    backgroundColor: "rgba(0,0,0,0.8)",
    justifyContent: "center",
    paddingHorizontal: 10,
    borderRadius: 13,
    paddingTop: 10,
  },
  selectedTextStyle: {
    color: "white",
    fontWeight: "bold",
  },
});
