import React, { useState, useEffect } from "react";
import { StatusBar } from "expo-status-bar";
import { StyleSheet, View, ActivityIndicator } from "react-native";
import { NavigationContainer } from "@react-navigation/native";
import Toast from "react-native-toast-message";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
import { supabase } from "./utils/supabase";
import Welcome from "./screens/Onboarding/Welcome";
import FirstLogin from "./screens/Onboarding/FirstLogin";
import Auth from "./screens/Onboarding/Auth";
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
  const [loading, setLoading] = useState(true);
  const [firstLogin, setFirstLogin] = useState(false);

  useEffect(() => {
    const getSession = async () => {
      setLoading(true);
      const {
        data: { session },
        error,
      } = await supabase.auth.getSession();
      if (error) {
        console.error("Error fetching session:", error);
        setLoading(false);
        return;
      }
      setSession(session);
      setLoading(false);

      if (session?.user) {
        const userId = session.user.id;
        console.log("User signed in, fetching profile..."); // Debug log

        const { data: userData, error: userError } = await supabase
          .from("profiles")
          .select("name")
          .eq("id", userId)
          .single();

        if (userError) {
          console.error("Error fetching user metadata:", userError);
        } else if (!userData || !userData.name) {
          console.log("First login detected"); // Debug log
          setFirstLogin(true);
        } else {
          setFirstLogin(false);
        }
      }
    };

    getSession();

    const { data: authListener } = supabase.auth.onAuthStateChange(
      (_event, session) => {
        setSession(session);
        if (session?.user) {
          const userId = session.user.id;

          supabase
            .from("profiles")
            .select("name")
            .eq("id", userId)
            .single()
            .then(({ data: userData, error: userError }) => {
              if (userError) {
                console.error("Error fetching user metadata:", userError);
              } else if (!userData || !userData.name) {
                console.log("First login detected in subscription"); // Debug log
                setFirstLogin(true);
              } else {
                setFirstLogin(false);
              }
            });
        }
      }
    );

    return () => {
      if (authListener?.subscription) {
        authListener.subscription.unsubscribe();
      }
    };
  }, []);

  if (loading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator size="large" color="#00ff00" />
      </View>
    );
  }

  return (
    <NavigationContainer>
      <View style={styles.container}>
        {session ? (
          firstLogin ? (
            <FirstLogin
              onProfileComplete={() => setFirstLogin(false)}
              session={session}
            />
          ) : (
            <Layout>
              <Tab.Navigator screenOptions={{ tabBarStyle: styles.navigator }}>
                <Tab.Screen
                  name="Generate"
                  component={Generate}
                  options={{ headerShown: false }}
                  initialParams={{ session }}
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
                  initialParams={{ session }}
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
                <Tab.Screen
                  name="Auth"
                  component={Auth}
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
  text: {
    fontSize: 20,
    color: "white",
    textAlign: "center",
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
  loadingContainer: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "black",
  },
});
