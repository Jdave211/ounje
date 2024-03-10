import React, { useState } from 'react';
import { Button, Image, View, StyleSheet, TouchableOpacity, Text } from 'react-native';
import * as ImagePicker from 'expo-image-picker';

export default function ImagePickerExample() {
  const [images, setImages] = useState([]);

  const pickImage = async () => {
    if (images.length >= 4) {
      return;
    }

    let result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ImagePicker.MediaTypeOptions.All,
      allowsEditing: true,
      aspect: [4, 3],
      quality: 1,
    });

    if (!result.cancelled) {
      setImages([...images, result.assets[0].uri]);
    }
  };

  const removeImage = (index) => {
    const newImages = [...images];
    newImages.splice(index, 1);
    setImages(newImages);
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
      <Button title="Generate" onPress={() => { /* Add your generate function here */ }} />
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
    width: 100,
    height: 100,
    margin: 5,
    position: 'relative',
  },
  image: {
    width: '100%',
    height: '100%',
  },
  addButton: {
    width: 100,
    height: 100,
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
});