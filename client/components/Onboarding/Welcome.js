import React, {useState, useEffect} from "react";
import { StyleSheet, View, Text, Image, ImageBackground, TouchableOpacity, Modal } from "react-native";
import Auth from "./Auth";
import SignIn from "./SignIn";
import { Ionicons } from "@expo/vector-icons";
import welcomepic3 from "../../assets/welcomepic3.jpg";



const Welcome = () => {
    const [signupModalVisible, setSignupModalVisible] = useState(false);
    const [signinModalVisible, setSigninModalVisible] = useState(false);

    const handleSignup = () => {
        setSignupModalVisible(true);
    }
    const handleSignin = () => {
        setSigninModalVisible(true);
    }

  return (
    <ImageBackground source={welcomepic3} style={styles.background}>
    <View style={styles.container}>
      <View style={styles.headings}>
        <Text style={styles.heading}>Recipes that you can trust.</Text>
        <Text style={styles.subheading}>Discover flavours you didn't even{'\n'}know were in your fridge.</Text>
      </View>
      <View style={styles.buttonContainer}>
        <TouchableOpacity style={styles.signupButton} onPress={handleSignup}>
          <Text style={styles.text}>Get Started</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.signinButton} onPress={handleSignin}>
          <Text style={styles.text}>Sign In</Text>
        </TouchableOpacity>
      </View>
      <Modal
          animationType="slide"
          transparent={true}
          visible={signupModalVisible}
          onRequestClose={() => {
            setModalVisible(!modalVisible);
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
            setModalVisible(!modalVisible);
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
      resizeMode: 'cover', // or 'stretch'
      justifyContent: 'center',
      alignItems: 'center',
      backgroundColor: 'rgba(0, 0, 0, 0.5)'
    },
    container: {
      flex: 1,
      justifyContent: 'flex-end',
      paddingBottom: '17%',
    },
    headings: {
        marginRight: '12%',
    },
    heading: {
      color: 'white',
      fontSize: 24,
      fontWeight: 'bold',
    },
    subheading: {
        color: 'white',
        fontSize: 14,
        fontWeight: '300',
        marginTop: 5,
    },
    buttonContainer: {
      alignItems: 'center',
      justifyContent: 'center',
      marginTop: 15,
    },
    signupButton: {
        alignItems: 'center',
      backgroundColor: 'green',
      paddingTop: 10,
      borderRadius: 10,
      marginTop: 20,
      width: '100%',
      height: 40,
    },
    signinButton: {
        alignItems: 'center',
      paddingTop: 15,
    },
    text: {
      color: 'white',
    },
    modalView: {
        flex: 0.50,
        backgroundColor: "black",
        justifyContent: "flex-end",
        marginTop:'auto',
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