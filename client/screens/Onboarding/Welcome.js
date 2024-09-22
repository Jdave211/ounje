import React, { useState } from "react";
import {
  StyleSheet,
  View,
  Text,
  ImageBackground,
  TouchableOpacity,
  Modal,
  StatusBar,
} from "react-native";
import Auth from "./Auth";
import SignIn from "./SignIn";
import { Ionicons } from "@expo/vector-icons";
import welcomepic3 from "../../assets/welcomepic3.jpg";
import { LinearGradient } from "expo-linear-gradient";
import { useNavigation } from "@react-navigation/native";
import Toast from "react-native-toast-message";
import { useAppStore } from "../../stores/app-store"; // Import useAppStore

const Welcome = () => {
  const [signupModalVisible, setSignupModalVisible] = useState(false);
  const [signinModalVisible, setSigninModalVisible] = useState(false);
  const navigation = useNavigation();
  const set_user_id = useAppStore((state) => state.set_user_id); // Get the set_user_id function from the store

  const handleSignup = () => {
    setSignupModalVisible(true);
  };

  const handleSignin = () => {
    setSigninModalVisible(true);
  };

  const continueAsGuest = () => {
    const guestUserId = "guest_" + new Date().getTime(); // Create a unique guest user ID
    set_user_id(guestUserId); // Set the user ID for guest access
    Toast.show({
      type: "success",
      text1: "Guest Sign In",
      text2: "You are now signed in as a guest.",
    });
    console.log("Continuing as guest with ID:", guestUserId);
  };

  return (
    <ImageBackground source={welcomepic3} style={styles.background}>
      {/*change the UI of the welcom screen for the android side */}
      <StatusBar backgroundColor={'#0001'}/>
      <LinearGradient
        colors={["rgba(0,0,0,0.6)", "transparent"]}
        style={styles.overlay}
      />
      <View style={styles.container}>
        <View style={styles.headings}>
          <Text style={styles.heading}>Recipes that you can trust.</Text>
          <Text style={styles.subheading}>
            Discover flavours you didn't even{"\n"}know were in your fridge.
          </Text>
        </View>
        <View style={styles.buttonContainer}>
          <TouchableOpacity style={styles.signupButton} onPress={handleSignup}>
            <Text style={styles.text}>Get Started</Text>
          </TouchableOpacity>
          <TouchableOpacity style={styles.signinButton} onPress={handleSignin}>
            <Text style={[styles.text, styles.signinText]}>Sign In</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={styles.guestButton}
            onPress={continueAsGuest}
          >
            <Text style={styles.guestText}>Continue as Guest ~</Text>
          </TouchableOpacity>
        </View>
        <Modal
          animationType="slide"
          transparent={true}
          visible={signupModalVisible}
          onRequestClose={() => {
            setSignupModalVisible(false);
          }}
        >
          <View style={styles.modalView}>
            <TouchableOpacity
              style={styles.close}
              onPress={() => setSignupModalVisible(false)}
            >
              <Ionicons name="exit" size={30} color="white" />
            </TouchableOpacity>
            <Auth />
          </View>
        </Modal>
        <Modal
          animationType="slide"
          transparent={true}
          visible={signinModalVisible}
          onRequestClose={() => {
            setSigninModalVisible(false);
          }}
        >
          <View style={styles.modalView}>
            <TouchableOpacity
              style={styles.close}
              onPress={() => setSigninModalVisible(false)}
            >
              <Ionicons name="exit" size={30} color="white" />
            </TouchableOpacity>
            <SignIn />
          </View>
        </Modal>
      </View>
    </ImageBackground>
  );
};

const styles = StyleSheet.create({
  background: {
    flex: 1,
    resizeMode: "cover", // or 'stretch'
    justifyContent: "center",
    alignItems: "center",
  },
  overlay: {
    position: "absolute",
    left: 0,
    right: 0,
    top: 0,
    bottom: 0,
  },
  container: {
    flex: 1,
    justifyContent: "flex-end",
    paddingBottom: "17%",
  },
  headings: {
    marginRight: "12%",
  },
  heading: {
    color: "white",
    fontSize: 24,
    fontWeight: "bold",
  },
  subheading: {
    color: "white",
    fontSize: 14,
    fontWeight: "300",
    marginTop: 5,
  },
  buttonContainer: {
    alignItems: "center",
    justifyContent: "center",
    marginTop: 15,
  },
  signupButton: {
    alignItems: "center",
    backgroundColor: "green",
    paddingTop: 10,
    borderRadius: 10,
    marginTop: 20,
    width: "100%",
    height: 40,
  },
  signinButton: {
    alignItems: "center",
    paddingTop: 15,
  },
  text: {
    color: "white",
    fontWeight: "bold",
  },
  signinText: {
    fontWeight: "bold",
    paddingBottom: 5,
    fontSize: 16,
  },
  guestButton: {
    alignItems: "center",
    paddingTop: 10,
    borderRadius: 10,
    marginTop: 5,
  },
  guestText: {
    color: "#B2FFFF",
    fontStyle: "italic",
    fontWeight: "bold",
    fontSize: 13,
  },
  modalView: {
    flex: 0.8,
    backgroundColor: "black",
    justifyContent: "flex-end",
    marginTop: "auto",
    borderRadius: 20,
  },
  close: {
    position: "absolute",
    top: 5,
    right: 15,
    zIndex: 1,
  },
});

export default Welcome;
