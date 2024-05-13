import React, { useState } from 'react';
import { Button, Image, View, StyleSheet, TouchableOpacity, Text } from 'react-native';
import * as ImagePicker from 'expo-image-picker';
import * as FileSystem from 'expo-file-system';
import Constants from 'expo-constants';
import { ActionSheetIOS } from 'react-native';
import { Linking } from 'react-native';

export default function ImagePickerExample() {
  const [images, setImages] = useState([]);
  const [imageUris, setImageUris] = useState([]);
  const API_KEY = process.env.OPENAI_API_KEY;
  const genAI = new GoogleGenerativeAI(API_KEY);


  const pickImage = async () => {
    if (images.length >= 4) {
      return;
    }

    const { status: cameraRollPerm } = await ImagePicker.requestMediaLibraryPermissionsAsync();

    if (cameraRollPerm !== 'granted') {
      alert('Sorry, we need camera roll permissions to make this work! Please go to Settings > Oúnje and enable the permission.');
      Linking.openSettings();
      return;
    }
  
    const { status: cameraPerm } = await ImagePicker.requestCameraPermissionsAsync();
  
    if (cameraPerm !== 'granted') {
      alert('Sorry, we need camera permissions to make this work! Please go to Settings > Oúnje and enable the permission.');
      Linking.openSettings();
      return;
    }
  
    ActionSheetIOS.showActionSheetWithOptions(
      {
        options: ['Cancel', 'Take Photo', 'Choose from Library'],
        cancelButtonIndex: 0,
      },
      async (buttonIndex) => {
        if (buttonIndex === 1) {
          let result = await ImagePicker.launchCameraAsync({
            mediaTypes: ImagePicker.MediaTypeOptions.All,
            allowsEditing: true,
            aspect: [4, 3],
            quality: 1,
          });
  
          if (!result.cancelled) {
            setImages([...images, result.assets[0].uri]);
          }
        } else if (buttonIndex === 2) {
          let result = await ImagePicker.launchImageLibraryAsync({
            mediaTypes: ImagePicker.MediaTypeOptions.All,
            allowsEditing: true,
            aspect: [4, 3],
            quality: 1,
          });
  
          if (!result.cancelled) {
            setImages([...images, result.assets[0].uri]);
          }
        }
      }
    );
  };

  const removeImage = (index) => {
    const newImages = [...images];
    newImages.splice(index, 1);
    setImages(newImages);
  };

  async function convertImageToBase64(uri) {
    try {
      const base64 = await FileSystem.readAsStringAsync(uri, { encoding: FileSystem.EncodingType.Base64 });
      return base64; // Prefix with 'data:image/jpeg;base64,' if needed
    } catch (error) {
      console.error('Error converting to base64:', error);
    }
  }


const sendImages = async () => {
  const formData = new FormData();

  for (let i = 0; i < images.length; i++) {
    const imageUri = images[i];
    const base64Image = await convertImageToBase64(imageUri);
    console.log(formData);

    formData.append('images', {
      uri: `${base64Image}`,
      type: 'image/jpeg', // or whichever type your image is
      name: `image${i + 1}.jpeg`,
    });
  }

  const base64Images = await Promise.all(images.map(convertImageToBase64));
    const prompt = "List all the food items (not brand names) in this image and store them in an array. Try and be really specific. The format should be: ['oatmeal', 'sugar', 'crushed tomatoes'...]";

    try {
      const response = await fetch('/analyze', { // Call your backend endpoint
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt, images: base64Images }),
      });

      if (response.ok) {
        const data = await response.json();
        console.log(data.result); // Handle the API response (display, etc.)
      } else {
        console.error('Error:', response.statusText); // Handle API errors
      }
    } catch (error) {
      console.error('Network error:', error); // Handle network errors
    }
};

  return (
    <View style={styles.container}>
      <View style={styles.imageContainer}>
        {images.map((image, index) => (
          <View key={index} style={styles.imageBox}>
            <TouchableOpacity style={styles.removeButton} onPress={() => removeImage(index)}>
              <Text style={styles.removeButtonText}>-</Text>
            </TouchableOpacity>
            <Image source={{ uri: image }} style={styles.image} />
          </View>
        ))}
        {images.length < 4 && (
          <TouchableOpacity style={styles.addButton} onPress={pickImage}>
            <Text style={styles.addButtonText}>+</Text>
          </TouchableOpacity>
        )}
      </View>
      <View style={styles.buttonContainer}>
      <TouchableOpacity 
        style={styles.buttonContainer} 
        onPress={sendImages} 
        disabled={images.length === 0}
      >
        <Text style={styles.buttonText}>Generate</Text>
      </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 50,
  },
  imageContainer: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    marginBottom: 20,
    
  },
  imageBox: {
    width: 70,
    height: 70,
    margin: 5,
    position: 'relative',
  },
  image: {
    width: '100%',
    height: '100%',
  },
  addButton: {
    width: 50,
    height: 50,
    backgroundColor: '#f0f0f0',
    justifyContent: 'center',
    alignItems: 'center',
    margin: 5,
  },
  addButtonText: {
    fontSize: 20,
    color: '#888',
  },
  removeButton: {
    position: 'absolute',
    right: 0,
    top: 0,
    backgroundColor: 'red',
    width: 20,
    height: 20,
    borderRadius: 10,
    justifyContent: 'center',
    alignItems: 'center',
    zIndex: 1,
  },
  removeButtonText: {
    color: 'white',
    fontSize: 15,
  },
  buttonContainer: {
    width: 200,
    height: 50,
    backgroundColor: 'green',
    borderRadius: 10,
    justifyContent: 'center',
    alignItems: 'center',
  },
  buttonText: {
    color: '#fff',
    fontWeight: 'bold',
  },
});