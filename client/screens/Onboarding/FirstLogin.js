import React, { useState } from 'react';
import { View, Text, TextInput, Button, Alert, Image, StyleSheet, TouchableOpacity, ImageBackground } from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import { supabase } from "../../utils/supabase";
import { MaterialCommunityIcons } from '@expo/vector-icons';
import name_bg from '../../assets/name_bg.jpg';
import diet_bg from '../../assets/diet_bg.jpeg';
import fridge_bg from '../../assets/fridge_bg.jpg';


const Introduction = () => {
  const [name, setName] = useState('');
  const [dietaryRestrictions, setDietaryRestrictions] = useState([]);
  const [fridgeImage, setFridgeImage] = useState(null);
  const [currentQuestion, setCurrentQuestion] = useState(0);

  const bg = [name_bg, diet_bg, fridge_bg]

  const dietaryRestrictionsOptions = [
    'Vegetarian',
    'Lactose Intolerant',
    'Nut Free',
    'Kosher',
    'Halal',
    ];

  const pickImage = async () => {
    let result = await ImagePicker.launchCameraAsync();

    if (!result.cancelled) {
      setFridgeImage(result.uri);
    }
  };

  const saveProfile = async () => {
    const user = supabase.auth.user();

    const updates = {
      id: user.id,
      name: name,
      dietary_restrictions: dietaryRestrictions,
      fridge_image: fridgeImage,
    };

    let { error } = await supabase
      .from('profiles')
      .upsert(updates, {
        returning: 'minimal', // Don't return the value after inserting
      });

    if (error) {
      Alert.alert('Error saving profile', error.message);
    } else {
      Alert.alert('Profile saved successfully');
    }
  };

  const questions = [
    <View style={styles.name}>
    <Text style={styles.name_text}>Hi there, what is your name?</Text>
    <TextInput
      style={{ height: 40, borderColor: 'gray', borderWidth: 2, color: 'white', fontWeight: 'bold', marginTop: 20}}
      onChangeText={text => setName(text)}
      value={name}
    />
  </View>,
    <View style={styles.name}>
    <Text style={styles.name_text}>Do you have any dietary restrictions?</Text>
    <TextInput
      style={{ height: 40, borderColor: 'gray', borderWidth: 2, color: 'white', fontWeight: 'bold', marginTop: 20,}}
      onChangeText={text => setName(text)}
      value={name}
    />
  </View>,
    <View>
      <Button title="Take a picture of your fridge" onPress={pickImage} />
      {fridgeImage && <Image source={{ uri: fridgeImage }} style={{ width: 200, height: 200 }} />}
      <Button title="Save Profile" onPress={saveProfile} />
    </View>
  ];

  return (
<ImageBackground source={bg[currentQuestion]} style={styles.container}>
    <View style={styles.container}>
      {questions[currentQuestion]}
    </View>
    <TouchableOpacity style={styles.next_button}onPress={() => {
      if (name.trim() === '') {
        Alert.alert('Error', 'Name is required');
      } else {
        setCurrentQuestion(currentQuestion + 1);
      }
    }}>
        <MaterialCommunityIcons name="page-next" size={24} color="white" />
    </TouchableOpacity>
</ImageBackground>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 20,
    justifyContent: 'center',
    padding: 20,
  },
  name_text: {
    color: 'white',
    fontWeight: 'bold',
  },
  name: {
    backgroundColor: 'black',
    padding: 20,
    borderRadius: 10,
    borderColor: 'white',
    borderWidth: 1,
    color: 'white',
  },
  next_button: {
    position: 'absolute',
    right: 20,
    bottom: 70,
    backgroundColor: 'black',
    padding: 10,
    borderRadius: 10,
    alignItems: 'center',
  },
});

export default Introduction;