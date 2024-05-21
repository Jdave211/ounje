import React, { useState, useEffect } from "react";
import { StatusBar } from "expo-status-bar";
import { StyleSheet, View } from "react-native";
import { NavigationContainer } from "@react-navigation/native";
import Toast from "react-native-toast-message";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
// import './shim.js' // important to import this shim for crypto

import { supabase } from "./utils/supabase";
import SignIn from "./components/Onboarding/Auth";
import Layout from "./_layout";
import SavedRecipes from "./screens/SavedRecipes";
import Inventory from "./screens/Inventory";
import Profile from "./screens/Profile";
import Community from "./screens/Community";
import Generate from "./screens/Generate/Generate";
import CheckIngredients from "./screens/Generate/CheckIngredients";
import RecipeOptions from "./screens/Generate/RecipeOptions";

const Tab = createBottomTabNavigator();

export default function App() {
  const [session, setSession] = useState(null);

  useEffect(() => {
    const getSession = async () => {
      const {
        data: { session },
        error,
      } = await supabase.auth.getSession();
      if (error) {
        console.error("Error fetching session:", error);
        return; // Exit the function if there's an error
      }
      setSession(session);
    };

    getSession();

    const subscription = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session);
    });
    if (subscription.unsubscribe) {
      return () => subscription.unsubscribe();
    }
  }, []);

  return (
    <NavigationContainer>
      <View style={styles.container}>
        {session ? (
          <Layout>
            <Tab.Navigator screenOptions={{ tabBarStyle: styles.navigator }}>
              <Tab.Screen
                name="Generate"
                component={Generate}
                options={{ headerShown: false }}
              />
              <Tab.Screen
                name="SavedRecipes"
                component={SavedRecipes}
                options={{ headerShown: false }}
              />
              <Tab.Screen
                name="Community"
                component={Community}
                options={{ headerShown: false }}
              />
              <Tab.Screen
                name="Inventory"
                component={Inventory}
                options={{ headerShown: false }}
              />
              <Tab.Screen
                name="Profile"
                component={Profile}
                options={{ headerShown: false }}
              />
              <Tab.Screen
                name="CheckIngredients"
                component={CheckIngredients}
                options={{ headerShown: false }}
              />
              <Tab.Screen
                name="RecipeOptions"
                component={RecipeOptions}
                options={{ headerShown: false }}
              />
            </Tab.Navigator>
          </Layout>
        ) : (
          <SignIn />
        )}

        <StatusBar style="light" />
      </View>
      <Toast />
    </NavigationContainer>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "black",
    color: "white",
  },
  text: {
    fontSize: 20,
    color: "white",
    textAlign: "center",
  },

  // why doesn't any of these work?
  navigator: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    height: 60, // Adjust as needed
    backgroundColor: "red",
    opacity: 0.8,
    borderWidth: 2,
    borderColor: "pink", // hun?
  },
});
