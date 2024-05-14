import React, {useState} from 'react';
import { View, Text, StyleSheet } from 'react-native';
import FoodRow from '../components/FoodRow';
import ImageUploadForm from '../components/ImageUploadForm';

const Generate = () => {
  const [isLoading, setIsLoading] = useState(true);

  return (
    <View style={styles.container}>
      <Text style={styles.text}></Text>
      <ImageUploadForm/>
      <View style={styles.foodRowContainer}>
        <FoodRow/>
      </View>
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

export default Generate;