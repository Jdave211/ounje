import React, { useState } from 'react';
import { View, Text, TextInput, Button, Alert, Image, StyleSheet, TouchableOpacity, ImageBackground } from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import { supabase } from "../../utils/supabase";
import { MaterialCommunityIcons } from '@expo/vector-icons';
import name_bg from '../../assets/name_bg.jpeg';
import diet_bg from '../../assets/diet_bg.jpeg';
import fridge_bg from '../../assets/fridge_bg.jpeg';


const Introduction = () => {
  const [name, setName] = useState('');
  const [dietaryRestrictions, setDietaryRestrictions] = useState([]);
  const [fridgeImage, setFridgeImage] = useState(null);
  const [currentQuestion, setCurrentQuestion] = useState(0);

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
    <ImageBackground source={name_bg} style={styles.name}>
    <Text style={styles.name_text}>Hi there, what is your name?</Text>
    <TextInput
      style={{ height: 40, borderColor: 'gray', borderWidth: 2 }}
      onChangeText={text => setName(text)}
      value={name}
    />
    <TouchableOpacity style={styles.next_button}onPress={() => {
      if (name.trim() === '') {
        Alert.alert('Error', 'Name is required');
      } else {
        setCurrentQuestion(currentQuestion + 1);
      }
    }}>
        <MaterialCommunityIcons name="page-next" size={24} color="white" />
    </TouchableOpacity>
    </ImageBackground>,
    <View>
      <Text>What are your dietary restrictions?</Text>
      {/* Here you should implement a multi-select input for dietary restrictions */}
      <Button title="Next" onPress={() => setCurrentQuestion(currentQuestion + 1)} />
    </View>,
    <View>
      <Button title="Take a picture of your fridge" onPress={pickImage} />
      {fridgeImage && <Image source={{ uri: fridgeImage }} style={{ width: 200, height: 200 }} />}
      <Button title="Save Profile" onPress={saveProfile} />
    </View>
  ];

  const bg = [name_bg, diet_bg, fridge_bg]

  return (

    <View style={styles.container}>
      {questions[currentQuestion]}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 20,
    marginTop: 50,
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
  },
    next_button: {
        flexDirection: 'flex-end',
        backgroundColor: 'green',
        padding: 10,
        borderRadius: 10,
        alignItems: 'center',
        marginTop: 10,
    },
});

export default Introduction;