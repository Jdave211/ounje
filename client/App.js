import React, { useState, useEffect } from "react";
import { StatusBar } from "expo-status-bar";
import { StyleSheet, View } from "react-native";
import { NavigationContainer } from "@react-navigation/native";
import Toast from "react-native-toast-message";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
import { supabase } from "./utils/supabase";
import Welcome from "./screens/Onboarding/Welcome";
import FirstLogin from "./screens/Onboarding/FirstLogin";
import Layout from "./_layout";
import SavedRecipes from "./screens/SavedRecipes";
import Inventory from "./screens/Inventory";
import Profile from "./screens/Profile";
import Community from "./screens/Community";
import Generate from "./screens/Generate/Generate";
import CheckIngredients from "./screens/Generate/CheckIngredients";

const Tab = createBottomTabNavigator();

export default function App() {
  const [session, setSession] = useState(null);
  const [firstLogin, setFirstLogin] = useState(false);

  const fetchSession = async () => {
    const { data: { session }, error } = await supabase.auth.getSession();
    if (error) {
      console.error("Error fetching session:", error);
      return;
    }
    setSession(session);
    checkFirstLogin(session);
  };

  const checkFirstLogin = async (session) => {
    if (session?.user) {
      const userId = session.user.id;

      const { data: profileData, error: profileError } = await supabase
        .from('profiles')
        .select('name')
        .eq('id', userId)
        .single();

      if (profileError) {
        console.error("Error fetching profile:", profileError);
      } else {
        console.log('Profile data:', profileData);

        if (!profileData || !profileData.name) {
          console.log('First login detected');
          setFirstLogin(true);
        } else {
          console.log('Existing user detected');
          setFirstLogin(false);
        }
      }
    }
  };

  useEffect(() => {
    fetchSession();

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session);
      checkFirstLogin(session);
    });

    return () => {
      if (subscription) subscription.unsubscribe();
    };
  }, []);

  useEffect(() => {
    if (session) {
      checkFirstLogin(session);
    }
  }, [session]);

  useEffect(() => {
    if (!firstLogin) {
      console.log("First login completed, refreshing session...");
      fetchSession();
    }
  }, [firstLogin]);

  return (
    <NavigationContainer>
      <View style={styles.container}>
        {session ? (
          firstLogin ? (
            <FirstLogin onProfileComplete={() => setFirstLogin(false)} />
          ) : (
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
              </Tab.Navigator>
            </Layout>
          )
        ) : (
          <Welcome />
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
  navigator: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    height: 60,
    backgroundColor: "red",
    opacity: 0.8,
    borderWidth: 2,
    borderColor: "pink",
  },
});
