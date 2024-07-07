import 'react-native-gesture-handler';
import React, { useState, useEffect, useCallback } from "react";
import { StatusBar } from "expo-status-bar";
import { StyleSheet, View, ActivityIndicator } from "react-native";
import {
  NavigationContainer,
  useNavigationContainerRef,
} from "@react-navigation/native";
import Toast from "react-native-toast-message";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
import { createStackNavigator } from "@react-navigation/stack";
import { supabase } from "./utils/supabase";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { QueryClient, QueryClientProvider } from "react-query";
import {useAppStore} from "./stores/app-store";

import Welcome from "./screens/Onboarding/Welcome";
import FirstLogin from "./screens/Onboarding/FirstLogin";
import Auth from "./screens/Onboarding/Auth";
import Layout from "./_layout";
import SavedRecipes from "./screens/Collection";
import Inventory from "./screens/Inventory";
import Profile from "./screens/Profile";
import Community from "./screens/Community";
import Generate from "./screens/Generate/Generate";
import RecipeOptions from "./screens/Generate/RecipeOptions";
import RecipePage from "./screens/RecipePage";
import CountCalories from "./screens/CountCalories";
import Settings from "./screens/Settings/Settings";
import PremiumSubscription from "./screens/Settings/PremiumSubscription";

const Tab = createBottomTabNavigator();
const Stack = createStackNavigator();

function GenerateStack({ route }) {
  const { session } = route.params;

  return (
    <Stack.Navigator screenOptions={{ headerShown: false }}>
      <Stack.Screen
        name="Generate"
        component={Generate}
        initialParams={{ session }}
      />
      <Stack.Screen
        name="RecipeOptions"
        component={RecipeOptions}
        initialParams={{ session }}
      />
      <Stack.Screen
        name="RecipePage"
        component={RecipePage}
        initialParams={{ session }}
      />
    </Stack.Navigator>
  );
}

function CollectionStack({ route }) {
  const { session } = route.params;

  return (
    <Stack.Navigator screenOptions={{ headerShown: false }}>
      <Stack.Screen
        name="CollectionPage"
        component={SavedRecipes}
        initialParams={{ session }}
      />
      <Stack.Screen
        name="RecipePage"
        component={RecipePage}
        initialParams={{ session }}
      />
    </Stack.Navigator>
  );
}

function ProfileStack({ route }) {
  const { session } = route.params;

  return (
    <Stack.Navigator screenOptions={{ headerShown: false }}>
      <Stack.Screen
        name="Profile"
        component={Profile}
        initialParams={{ session }}
      />
      <Stack.Screen
        name="Settings"
        component={Settings}
        initialParams={{ session }}
      />
      <Stack.Screen
        name="PremiumSubscription"
        component={PremiumSubscription}
        initialParams={{ session }}
      />
    </Stack.Navigator>
  );
}

export default function App() {
  const navigationRef = useNavigationContainerRef(); // Create navigation reference
  const [session, setSession] = useState(null);
  const [loading, setLoading] = useState(true);
  const [firstLogin, setFirstLogin] = useState(false);

  const userId = useAppStore((state) => state.userId);
  const set_user_id = useAppStore((state) => state.set_user_id);

  const queryClient = new QueryClient();

  const getSession = useCallback(async () => {
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

      set_user_id(userId);

      console.log("User signed in, fetching profile...");

      const { data: userData, error: userError } = await supabase
        .from("profiles")
        .select("name")
        .eq("id", userId)
        .single();

      if (userError) {
        console.error("Error fetching user metadata:", userError);
      } else if (!userData || !userData.name) {
        console.log("First login detected");
        setFirstLogin(true);
      } else {
        setFirstLogin(false);
      }
    }
  }, []);

  useEffect(() => {
    getSession();

    const { data: authListener } = supabase.auth.onAuthStateChange(
      (_event, session) => {
        setSession(session);
        if (session?.user) {
          const userId = session.user.id;
          set_user_id(userId)

          supabase
            .from("profiles")
            .select("name")
            .eq("id", userId)
            .single()
            .then(({ data: userData, error: userError }) => {
              if (userError) {
                console.error("Error fetching user metadata:", userError);
              } else if (!userData || !userData.name) {
                console.log("First login detected in subscription");
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
  }, [getSession]);

  if (loading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator size="large" color="#00ff00" />
      </View>
    );
  }

  

  return (
    <GestureHandlerRootView>
      <QueryClientProvider client={queryClient}>
        <NavigationContainer ref={navigationRef}>
          <View style={styles.container}>
            {session ? (
              firstLogin ? (
                <FirstLogin
                  onProfileComplete={() => setFirstLogin(false)}
                  session={session}
                />
              ) : (
                <Layout>
                  <Tab.Navigator
                    initialRouteName="Home"
                    screenOptions={{ tabBarStyle: styles.navigator }}
                  >
                    <Tab.Screen
                      name="Home"
                      component={GenerateStack}
                      options={{ headerShown: false }}
                      initialParams={{ session }}
                    />
                    <Tab.Screen
                      name="Collection"
                      component={CollectionStack}
                      options={{ headerShown: false }}
                      initialParams={{ session }}
                    />
                    <Tab.Screen
                      name="Community"
                      component={Community}
                      options={{ headerShown: false }}
                    />
                    <Tab.Screen
                      name="Calories"
                      component={CountCalories}
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
                      name="Auth"
                      component={Auth}
                      options={{ headerShown: false }}
                    />
                    <Tab.Screen
                      name='ProfilePage'
                      component={ProfileStack}
                      options={{ headerShown: false }}
                      initialParams={{ session }}
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
      </QueryClientProvider>
    </GestureHandlerRootView>
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
