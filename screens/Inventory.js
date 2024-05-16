import React, {useState} from 'react';
import { View, Text, StyleSheet } from 'react-native';

const Inventory = () => {
    return (
        <View style={styles.container}>
        <Text style={styles.text}>Inventory</Text>
        </View>
    );
};

const styles = StyleSheet.create({
    container: {
      flex: 1,
      backgroundColor: 'black',
    },
    text: {
      color: 'white',
    },
    foodRowContainer: {
      position: 'absolute',
      bottom: 0,
      width: '100%',
      marginBottom: 70, 
    },
  });

export default Inventory;