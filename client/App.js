import "react-native-gesture-handler";
import React, { useState, useEffect, useCallback } from "react";
import { StatusBar } from "expo-status-bar";
import { StyleSheet, View, ActivityIndicator, Text } from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  NavigationContainer,
  useNavigationContainerRef,
} from "@react-navigation/native";
import ErrorBoundary from "./components/ErrorBoundary";
import Toast from "react-native-toast-message";
import { createBottomTabNavigator } from "@react-navigation/bottom-tabs";
import { createStackNavigator } from "@react-navigation/stack";
import { supabase } from "./utils/supabase";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { QueryClient, QueryClientProvider } from "react-query";
import { useAppStore } from "./stores/app-store";

import Welcome from "./screens/Onboarding/Welcome";
import FirstLogin from "./screens/Onboarding/FirstLogin";
import Auth from "./screens/Onboarding/Auth";
import Layout from "./_layout";
import Collection from "./screens/Collection";
import Inventory from "./screens/Inventory";
import Profile from "./screens/Profile";
import Community from "./screens/Community";
import Generate from "./screens/Generate/Generate";
import RecipeOptions from "./screens/Generate/RecipeOptions";
import RecipePage from "./screens/RecipePage";
import CountCalories from "./screens/Calories/CountCalories";
import Settings from "./screens/Settings/Settings";
import PremiumSubscription from "./screens/Settings/PremiumSubscription";
import CaloriesPaywall from "./screens/Calories/CaloriesPaywall";

const Tab = createBottomTabNavigator();
const Stack = createStackNavigator();

function GenerateStack() {
  const isPremium = useAppStore((state) => state.is_premium);

  return (
    <Stack.Navigator screenOptions={{ headerShown: false }}>
      <Stack.Screen name="Generate" component={Generate} />
      <Stack.Screen name="RecipeOptions" component={RecipeOptions} />
      <Stack.Screen name="RecipePage" component={RecipePage} />
    </Stack.Navigator>
  );
}

function CollectionStack() {
  return (
    <Stack.Navigator screenOptions={{ headerShown: false }}>
      <Stack.Screen name="CollectionPage" component={Collection} />
      <Stack.Screen name="RecipePage" component={RecipePage} />
    </Stack.Navigator>
  );
}

function ProfileStack() {
  return (
    <Stack.Navigator screenOptions={{ headerShown: false }}>
      <Stack.Screen name="Profile" component={Profile} />
      <Stack.Screen name="Settings" component={Settings} />
      <Stack.Screen
        name="PremiumSubscription"
        component={PremiumSubscription}
      />
      <Stack.Screen name="CaloriesPaywall" component={CaloriesPaywall} />
      <Stack.Screen name="CountCalories" component={CountCalories} />
    </Stack.Navigator>
  );
}

export default function App() {
  const navigationRef = useNavigationContainerRef();
  const [session, setSession] = useState(null);
  const [loading, setLoading] = useState(true);
  const [firstLogin, setFirstLogin] = useState(false);
  const [error, setError] = useState(null);

  const set_user_id = useAppStore((state) => state.set_user_id);
  const user_id = useAppStore((state) => state.user_id);
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        retry: 2,
        onError: (error) => {
          console.error('Query error:', error);
        },
      },
    },
  });

  const getSession = useCallback(async () => {
    try {
      setLoading(true);
      // Ensure AsyncStorage is ready
      await AsyncStorage.getItem('test-key').catch(e => {
        console.error('AsyncStorage not ready:', e);
        throw new Error('Storage system not available');
      });

      // Check network connectivity
      const response = await fetch('https://kmvqftoebsmmkhxrgdye.supabase.co', {
        method: 'HEAD',
      }).catch(() => null);

      if (!response) {
        throw new Error('No network connection');
      }

      const {
        data: { session },
        error,
      } = await supabase.auth.getSession();
      
      if (error) {
        console.error("Error fetching session:", error);
        throw error;
      }

      setSession(session);

      if (session?.user) {
        const userId = session.user.id;
        set_user_id(userId);

        try {
          const { data: userData, error: userError } = await supabase
            .from("profiles")
            .select("name")
            .eq("id", userId)
            .single();

          if (userError) {
            console.error("Error fetching user metadata:", userError);
            setError(userError.message);
          } else if (!userData || !userData.name) {
            console.log("First login detected");
            setFirstLogin(true);
          } else {
            setFirstLogin(false);
          }
        } catch (profileError) {
          console.error("Profile fetch error:", profileError);
          setError("Failed to load user profile");
        }
      }
    } catch (e) {
      console.error("Session fetch error:", e);
      setError("Failed to initialize session");
    } finally {
      setLoading(false);
    }
  }, [set_user_id]);

  useEffect(() => {
    getSession();

    const { data: authListener } = supabase.auth.onAuthStateChange(
      (_event, session) => {
        setSession(session);
        if (session?.user) {
          const userId = session.user.id;
          set_user_id(userId);

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

  useEffect(() => {
    if (user_id) {
      setLoading(false);
    }
  }, [user_id]);

  if (loading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator size="large" color="#00ff00" />
      </View>
    );
  }

  if (error) {
    const isNetworkError = error.includes('network') || error.includes('connection');
    return (
      <View style={styles.errorContainer}>
        <Text style={styles.errorText}>
          {isNetworkError
            ? "No internet connection. Please check your network and try again."
            : `Error: ${error}`}
        </Text>
        {isNetworkError && (
          <Text
            style={[styles.errorText, styles.retryText]}
            onPress={() => {
              setError(null);
              getSession();
            }}
          >
            Tap to retry
          </Text>
        )}
      </View>
    );
  }

  return (
    <ErrorBoundary>
      <GestureHandlerRootView style={{ flex: 1 }}>
        <NavigationContainer ref={navigationRef}>
          <QueryClientProvider client={queryClient}>
            <View style={styles.container}>
              {user_id ? (
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
                      />
                      <Tab.Screen
                        name="Collection"
                        component={CollectionStack}
                        options={{ headerShown: false }}
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
                      />
                      <Tab.Screen
                        name="Auth"
                        component={Auth}
                        options={{ headerShown: false }}
                      />
                      <Tab.Screen
                        name="ProfilePage"
                        component={ProfileStack}
                        options={{ headerShown: false }}
                      />
                      <Tab.Screen
                        name="PremiumSubscription"
                        component={PremiumSubscription}
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
          </QueryClientProvider>
        </NavigationContainer>
      </GestureHandlerRootView>
    </ErrorBoundary>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#121212",
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
  errorContainer: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "#121212",
    padding: 20,
  },
  errorText: {
    color: "#ff4444",
    fontSize: 16,
    textAlign: "center",
    paddingHorizontal: 20,
    marginBottom: 10,
  },
  retryText: {
    color: "#4444ff",
    fontSize: 18,
    marginTop: 20,
    textDecorationLine: "underline",
  },
});
