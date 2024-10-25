import { StyleSheet, Text, View, Image, Dimensions, Alert } from "react-native";
import React from "react";
import pantry from "../../assets/pantry.png";
import { TouchableOpacity } from "react-native-gesture-handler";
import * as ImagePicker from 'expo-image-picker';
import { supabase } from "../../utils/supabase";


const screenWidth = Dimensions.get("window").width;

const Pantry = () => {
  const handleImagePick = async () => {
    // Request permissions for media library
    const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync();
    if (status !== 'granted') {
      Alert.alert('Permission required', 'We need permission to access your media library.');
      return;
    }

    // Launch the image picker
    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ImagePicker.MediaTypeOptions.Images,
      allowsEditing: true,
      aspect: [4, 3],
      quality: 1,
    });

    // Check if user canceled the picker
    if (!result.canceled) {
      const { uri } = result.assets[0];
      await uploadImage(uri);
    }
  };

  const uploadImage = async (uri) => {
    const fileName = uri.split('/').pop();
    const { data, error } = await supabase.storage
      .from('pantry_images')
      .upload(fileName, {
        uri: uri,
        type: 'image/jpeg', // Adjust if you have different types
      });

    if (error) {
      console.error('Error uploading image:', error);
      Alert.alert('Upload failed', 'Error uploading image. Please try again.');
    } else {
      console.log('Image uploaded successfully:', data);
      // Here you can update your database entry if needed
      // updateImageInDatabase(data.Key); // Use the appropriate key or URL
    }
  };

  return (
    <View>
      <Text style={styles.imageTitle}>Pantry</Text>
      <TouchableOpacity style={styles.imageWrapper} onPress={handleImagePick}>
        <Image source={pantry} style={styles.image} />
        <View style={styles.overlay}>
          <Text style={styles.overlayText}>Tap to add</Text>
        </View>
      </TouchableOpacity>
    </View>
  );
};

export default Pantry;

const styles = StyleSheet.create({
  imageWrapper: {
    position: "relative",
    margin: 10,
  },
  image: {
    borderRadius: 10,
    width: screenWidth * 0.25,
    height: screenWidth * 0.25,
  },
  overlay: {
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: "rgba(0, 0, 0, 0.5)",
    borderRadius: 10,
    justifyContent: "center",
    alignItems: "center",
  },
  overlayText: {
    color: "#fff",
    fontSize: screenWidth * 0.03,
  },
  imageTitle: {
    color: "#fff",
    fontSize: screenWidth * 0.04,
    fontWeight: "bold",
    textAlign: "center",
    marginBottom: 6,
  },
});
