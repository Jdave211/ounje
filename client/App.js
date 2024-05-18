import React, { useState, useEffect } from 'react';
import { StatusBar } from 'expo-status-bar';
import { StyleSheet, View } from 'react-native';
import { NavigationContainer } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
// import './shim.js' // important to import this shim for crypto

import { supabase } from './utils/supabase';
import SignIn from './components/Auth';
import Layout from './_layout';
import Generate from './screens/Generate';
import SavedRecipes from './screens/SavedRecipes';
import Inventory from './screens/Inventory';
import Profile from './screens/Profile';

const Tab = createBottomTabNavigator();

export default function App() {
  const [session, setSession] = useState(null);

  useEffect(() => {
    const getSession = async () => {
      const { data: { session }, error } = await supabase.auth.getSession();
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
                name='Inventory'
                component={Inventory}
                options={{ headerShown: false }}
              />
              <Tab.Screen 
                name='Profile' 
                component={Profile}
                options={{ headerShown: false }}
              />
            </Tab.Navigator>
            </Layout>
          ) : (
            <SignIn />
          )}
        
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