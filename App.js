import React, { useState, useEffect } from 'react';
import { StatusBar } from 'expo-status-bar';
import { StyleSheet, View } from 'react-native';
import { NavigationContainer } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { supabase } from './utils/supabase'; // Import your supabase client
import SignIn from './components/Auth'; // Import your SignIn component
import Layout from './_layout';
import Generate from './screens/Generate';
import SavedRecipes from './screens/SavedRecipes';
import Profile from './screens/Profile';

const Tab = createBottomTabNavigator();

export default function App() {
  const [session, setSession] = useState(null);

  useEffect(() => {
    const getSession = async () => {
      const { data: { session }, error } = await supabase.auth.getSession();
      if (error) {
        console.error("Error fetching session:", error);
        // Handle the error here (e.g., display an error message to the user)
        return; // Exit the function if there's an error
      }
      setSession(session);
    };
  
    getSession();
  
    const subscription = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session);
    });
  
    return () => subscription.unsubscribe();
  }, []);

  return (
    <NavigationContainer>
      <View style={styles.container}>
        <Layout>
          {session ? (
            <Tab.Navigator>
              <Tab.Screen 
                name='Generate' 
                component={Generate}
                options={{ headerShown: false }}
              />
              <Tab.Screen 
                name='SavedRecipes' 
                component={SavedRecipes}
                options={{ headerShown: false }}
              />
              <Tab.Screen 
                name='Profile' 
                component={Profile}
                options={{ headerShown: false }}
              />
            </Tab.Navigator>
          ) : (
            <SignIn /> // Render the SignIn component if there's no session
          )}
        </Layout>
        <StatusBar style="light" />
      </View>
    </NavigationContainer>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: 'black',
  },
  text: {
    fontSize: 20,
    color: 'white',
    textAlign: 'center',
  },
});