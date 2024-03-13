import React, { useState } from 'react';
import { View, Text, Button, StyleSheet } from 'react-native';

const Profile = () => {
    const [isSignedIn, setIsSignedIn] = useState(false); // replace this with actual sign in status

    const handleSignIn = () => {
        setIsSignedIn(true);
    };

    const handleSignOut = () => {
        setIsSignedIn(false);
    };

    return (
        <View style={styles.container}>
            {isSignedIn ? (
                <>
                    <Text style={styles.text}>User Profile</Text>
                    <Button title="Sign Out" onPress={handleSignOut} />
                </>
            ) : (
                <>
                    <Text style={styles.text}>Please Sign In</Text>
                    <Button title="Sign In" onPress={handleSignIn} />
                </>
            )}
        </View>
    );
};

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: 'black',
        justifyContent: 'center',
        alignItems: 'center',
    },
    text: {
        color: 'white',
    },
});

export default Profile;