import {
  StyleSheet,
  Text,
  View,
  Image,
  Dimensions,
  Alert,
  ActivityIndicator,
  Modal,
  TouchableOpacity,
} from "react-native";
import React, { useState, useEffect } from "react";
import pantry from "../../assets/pantry.png";
import * as ImagePicker from "expo-image-picker";
import { supabase } from "../../utils/supabase";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { AntDesign } from "@expo/vector-icons";

const screenWidth = Dimensions.get("window").width;

const Pantry = () => {
  const [selectedImageUri, setSelectedImageUri] = useState(null);
  const [isLoading, setIsLoading] = useState(false);
  const [modalVisible, setModalVisible] = useState(false);
  const [imageMessage, setImageMessage] = useState(""); // State for the image message

  // Load the image URI from AsyncStorage when the component mounts
  useEffect(() => {
    const loadImage = async () => {
      try {
        const uri = await AsyncStorage.getItem("pantryImageUri");
        if (uri) {
          setSelectedImageUri(uri);
        }
      } catch (error) {
        console.error("Failed to load image from storage:", error);
      }
    };

    loadImage();
  }, []);

  // Function to handle image pick
  const handleImagePick = async () => {
    const { status } = await ImagePicker.requestMediaLibraryPermissionsAsync();
    if (status !== "granted") {
      Alert.alert(
        "Permission required",
        "We need permission to access your media library."
      );
      return;
    }

    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ImagePicker.MediaTypeOptions.Images,
      allowsEditing: true,
      aspect: [4, 3],
      quality: 1,
    });

    if (!result.canceled) {
      const { uri } = result.assets[0];
      await uploadImage(uri);
    }
  };

  const uploadImage = async (uri) => {
    setIsLoading(true);
    const {
      data: { user },
      error: authError,
    } = await supabase.auth.getUser();
  
    if (authError || !user) {
      Alert.alert(
        "Not Authenticated",
        "You must be logged in to upload images."
      );
      setIsLoading(false);
      return;
    }
  
    const fileName = uri.split("/").pop();
    const { data, error } = await supabase.storage
      .from("pantry_images")
      .upload(fileName, {
        uri: uri,
        type: "image/jpeg",
      });
  
    if (error) {
      console.error("Error uploading image:", error);
      Alert.alert("Upload failed", "Error uploading image. Please try again.");
    } else {
      console.log("Image uploaded successfully:", data);
      const message = selectedImageUri ? "Image has been replaced." : "Image has been added."; // Determine message
      Alert.alert("Success", message, [
        {
          text: "OK",
          onPress: () => {
            setModalVisible(false); // Close modal after alert
          },
        },
      ]);
      setSelectedImageUri(uri);
      await AsyncStorage.setItem("pantryImageUri", uri);
    }
    setIsLoading(false);
  };
  
  const handleImagePress = () => {
    if (selectedImageUri) {
      // If an image exists, show the replace image modal
      setModalVisible(true);
    } else {
      // If no image exists, show the image picker directly
      handleImagePick();
    }
  };

  return (
    <View style={{ flex: 1 }}>
      {isLoading && (
        <View style={styles.loader}>
          <ActivityIndicator size="large" color="#38F096" />
        </View>
      )}
      <Text style={styles.imageTitle}>Pantry</Text>
      <TouchableOpacity style={styles.imageWrapper} onPress={handleImagePress}>
        <Image
          source={selectedImageUri ? { uri: selectedImageUri } : pantry} // Display selected image or default
          style={styles.image}
        />
        <View style={styles.overlay}>
          <Text style={styles.overlayText}>
            {selectedImageUri ? "Tap to eplace" : "Tap to add+"}
          </Text>
        </View>
      </TouchableOpacity>

      <Modal
        animationType="slide"
        transparent={true}
        visible={modalVisible}
        onRequestClose={() => setModalVisible(false)}
      >
        <View style={styles.modalOverlay}>
          <TouchableOpacity
            style={styles.close}
            onPress={() => setModalVisible(false)}
          >
            <AntDesign name="closecircle" size={30} color="white" />
          </TouchableOpacity>

          <View style={styles.modalView}>
            <Image
              source={selectedImageUri ? { uri: selectedImageUri } : pantry}
              style={styles.modalImage}
            />
            <TouchableOpacity
              style={styles.replaceButton}
              onPress={handleImagePick}
            >
              <Text style={styles.replaceText}>Replace Image</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>
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
  loader: {
    flex: 1,
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: "rgba(0, 0, 0, 0.5)",
    zIndex: 1,
  },
  modalOverlay: {
    flex: 1,
    backgroundColor: "rgba(0, 0, 0, 0.8)",
    justifyContent: "center",
    alignItems: "center",
  },
  close: {
    position: "absolute",
    top: 50,
    right: 20,
  },
  modalView: {
    backgroundColor: "#222",
    borderRadius: 10,
    padding: 20,
    alignItems: "center",
  },
  modalImage: {
    width: screenWidth * 0.75,
    height: screenWidth * 0.75,
    resizeMode: "contain",
  },
  replaceButton: {
    marginTop: 10,
    backgroundColor: "#282C35",
    borderRadius: 10,
    padding: 10,
    alignItems: "center",
  },
  replaceText: {
    color: "white",
    fontWeight: "bold",
  },
});
