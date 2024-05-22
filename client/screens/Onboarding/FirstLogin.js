import React, { useState } from 'react';
import { View, Text, TextInput, Alert, Image, StyleSheet, TouchableOpacity, ImageBackground } from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import { supabase } from "../../utils/supabase";
import { MaterialCommunityIcons } from '@expo/vector-icons';
import name_bg from '../../assets/name_bg.jpg';
import diet_bg from '../../assets/diet_bg.jpeg';
import fridge_bg from '../../assets/fridge_bg.jpg';
import camera_icon from '../../assets/camera_icon.png';
import { MultipleSelectList } from "../../components/MultipleSelectList";
import { FontAwesome5 } from '@expo/vector-icons';

const FirstLogin = ({ onProfileComplete }) => {
  const [name, setName] = useState('');
  const [dietaryRestrictions, setDietaryRestrictions] = useState([]);
  const [fridgeImage, setFridgeImage] = useState(null);
  const [currentQuestion, setCurrentQuestion] = useState(0);
  const [selected, setSelected] = useState([]);

  const bg = [name_bg, diet_bg, fridge_bg];

  const dietaryRestrictionsOptions = [
    'Vegetarian',
    'Lactose Intolerant',
    'Nut Free',
    'Diabetic',
  ];

  const pickImage = async () => {
    let result = await ImagePicker.launchCameraAsync();

    if (!result.cancelled) {
      setFridgeImage(result.uri);
    }
  };

  const saveProfile = async () => {
    const { data: { user }, error: userError } = await supabase.auth.getUser();

    if (userError) {
      Alert.alert('Error fetching user', userError.message);
      return;
    }

    const updates = {
      id: user.id,
      name: name,
      dietary_restriction: selected,
    };

    let { error } = await supabase
      .from('profiles')
      .upsert(updates, {
        returning: 'minimal',
      });

    if (error) {
      Alert.alert('Error saving profile', error.message);
    } else {
      Alert.alert('Profile saved successfully');
      onProfileComplete();
    }
  };

  const questions = [
    <View style={styles.name}>
      <Text style={styles.name_text}>Hi there, what is your name?</Text>
      <TextInput
        style={{ height: 40, borderColor: 'gray', borderWidth: 2, color: 'white', fontWeight: 'bold', marginTop: 20 }}
        onChangeText={text => setName(text)}
        value={name}
      />
    </View>,
    <View style={styles.name}>
      <Text style={styles.name_text}>Do you have any dietary restrictions?</Text>
      <MultipleSelectList
        setSelected={setSelected}
        selectedTextStyle={styles.selectedTextStyle}
        dropdownTextStyles={{ color: "white" }}
        data={dietaryRestrictionsOptions}
        save="value"
        maxHeight={900}
        placeholder={"Select dietary restrictions"}
        placeholderStyles={{ color: "white" }}
        arrowicon={
          <FontAwesome5 name="chevron-down" size={12} color={"white"} />
        }
        searchicon={
          <FontAwesome5 name="search" size={12} color={"white"} />
        }
        search={false}
        boxStyles={{
          marginTop: 10,
          marginBottom: 10,
          borderColor: "white",
        }}
        badgeStyles={{ backgroundColor: "green" }}
      />
    </View>,
    <View style={styles.fridge}>
      <Text style={styles.fridge_text}>And finally, please click here to take a picture of your fridge</Text>
      <TouchableOpacity style={styles.camera} onPress={pickImage}>
        <Image source={camera_icon} style={{ width: 50, height: 50 }} />
      </TouchableOpacity>
      {fridgeImage && <Image source={{ uri: fridgeImage }} style={{ width: 200, height: 200 }} />}
    </View>
  ];

  return (
    <ImageBackground source={bg[currentQuestion]} style={styles.container}>
      <View style={styles.container}>
        {questions[currentQuestion]}
      </View>
      {currentQuestion < 2 ? (
        <TouchableOpacity style={styles.next_button} onPress={() => {
          if (name.trim() === '' && currentQuestion === 0) {
            Alert.alert('Error', 'Name is required');
          } else {
            setCurrentQuestion(currentQuestion + 1);
          }
        }}>
          <MaterialCommunityIcons name="page-next" size={24} color="white" />
        </TouchableOpacity>
      ) : (
        <TouchableOpacity style={styles.next_button} onPress={saveProfile}>
          <MaterialCommunityIcons name="check-circle" size={24} color="white" />
        </TouchableOpacity>
      )}
    </ImageBackground>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    padding: 20,
  },
  name_text: {
    color: 'gray',
    fontWeight: 'bold',
  },
  name: {
    backgroundColor: 'black',
    padding: 20,
    borderRadius: 10,
    borderColor: 'white',
    borderWidth: 1,
  },
  fridge: {
    backgroundColor: 'gray',
    padding: 20,
    borderRadius: 10,
    borderColor: 'black',
    borderWidth: 1,
  },
  fridge_text: {
    color: 'black',
    fontWeight: 'bold',
    textAlign: 'center',
  },
  camera: {
    padding: 10,
    borderRadius: 10,
    alignItems: 'center',
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

export default FirstLogin;
