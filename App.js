import React from 'react';
import { StatusBar } from 'expo-status-bar';
import { StyleSheet, View } from 'react-native';
import { NavigationContainer } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import Layout from './_layout';
import Generate from './screens/Generate';
import SavedRecipes from './screens/SavedRecipes';
import Profile from './screens/Profile';

const Tab = createBottomTabNavigator();

export default function App() {
  return (
    <NavigationContainer>
      <View style={styles.container}>
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
              name='Profile' 
              component={Profile}
              options={{ headerShown: false }}
            />
            
          </Tab.Navigator>
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