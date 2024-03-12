import React, { useState } from 'react';
import { View, Text, StyleSheet, Image, TouchableOpacity } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import SignIn from './SignIn'; // Import the SignIn component

export default function Profile() {
    const [signedIn, setSignedIn] = useState(false); // Add a state variable for tracking sign-in status

    const navigation = useNavigation();

    if (!signedIn) {
        return <SignIn onSignIn={() => setSignedIn(true)} />; // Render the SignIn component if the user is not signed in
    }

    return (
        <View style={styles.container}>
        <View style={styles.imageContainer}>
            <Image
            source={require('../assets/profile.png')}
            style={styles.image}
            />
        </View>
        <View style={styles.textContainer}>
            <Text style={styles.text}>Name: John Doe</Text>
            <Text style={styles.text}>Email: jagadave@gmail.com</Text>

        </View>
        </View>
    )
};