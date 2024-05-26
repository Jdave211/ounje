import React, { useState, useEffect } from "react";
import { View, Text, StyleSheet, TouchableOpacity, ImageBackground, Alert, ScrollView } from "react-native";
import { useNavigation } from "@react-navigation/native";
import { SelectList } from 'react-native-dropdown-select-list';
import { FontAwesome5 } from "@expo/vector-icons";
import GenerateRecipes from "@components/GenerateRecipes";
import Loading from "@components/Loading";
import generate_bg from "@assets/generate_bg.jpg";
import { supabase } from "@utils/supabase";

export default function Generate({ route }) {
  const { session } = route.params;
  const [isLoading, setIsLoading] = useState(false);
  const [selected, setSelected] = useState(null);
  const [name, setName] = useState(' ');
  const [recipes, setRecipes] = useState([]);
  const navigation = useNavigation();

  const flavors = ['sweet', 'sour', 'spicy', 'umami'];

  const handleLoading = (loading) => {
    setIsLoading(loading);
  };

  useEffect(() => {
    const fetchProfile = async () => {
      const userId = session?.user?.id;
      if (userId) {
        const { data: profileData, error: profileError } = await supabase
          .from('profiles')
          .select('name')
          .eq('id', userId)
          .single();

          if(name){

          
        if (profileError) {
          Alert.alert('Error fetching profile', profileError.message);
        } else {
          const firstName = profileData.name.split(' ')[0]; // get the first name
        setName(firstName);
        }
        }
      }
    };

    fetchProfile();
  }, [session]);

  return (
    <ImageBackground source={generate_bg} style={styles.backgroundImage}>
      <View style={styles.overlay}>
        <View style={styles.header}>
          <Text style={styles.text}>Hi {name}, </Text>
          <Text style={styles.text}>Select your preferences<Text style={{color:'black'}}>, and get to</Text> cooking...</Text>
        </View>
        <View style={styles.content}>
          <SelectList
            setSelected={setSelected}
            data={flavors}
            placeholder="Select a flavor"
            placeholderStyles={{ color: "white", fontSize: 20, fontWeight: "bold" }}
            inputStyles={{ color: "white", fontWeight: "bold" }}
            selectedTextStyle={styles.selectedTextStyle}
            dropdownTextStyles={{ color: "white", fontWeight: "bold" }}
            save="value"
            maxHeight={900}
            arrowicon={
              <FontAwesome5 name="chevron-down" size={12} color={"white"} />
            }
            search={false}
            boxStyles={{
              marginTop: 10,
              marginBottom: 10,
              borderColor: "white",
            }}
            defaultOption={{ key:'1', value:'What flavor are you feeling?' }}
          />
          <ScrollView style={{flex: 0.5}}>
  <GenerateRecipes onLoading={handleLoading} onRecipesGenerated={setRecipes} />
  <View style={{padding: 10}}>
            {isLoading ? (
              <Loading />
            ) : (
              recipes.map((recipe, index) => (
                <View key={index}>
                  <Text style={{color: 'white'}}>{JSON.stringify(recipe)}</Text>
                </View>
              ))
            )}
          </View>
</ScrollView>
        </View>
      </View>
    </ImageBackground>
  );
};

const styles = StyleSheet.create({
  backgroundImage: {
    flex: 1,
    resizeMode: "cover",
  },
  overlay: {
    flex: 1,
    justifyContent: "flex-end",
  },
  header: {
    height: '40%',
    alignItems: "left",
    justifyContent: "center",
    paddingHorizontal: 10,
    borderBottomLeftRadius: 10,
    borderBottomRightRadius: 10,
  },
  text: {
    color: "white",
    fontSize: 20,
    fontWeight: "bold",
  },
  content: {
    height: '60%',
    backgroundColor: 'rgba(0,0,0,0.8)',
    justifyContent: "center",
    paddingHorizontal: 10,
    borderRadius: 13,
    paddingTop: 10,
  },
  foodRowContainer: {
    width: "100%",
    marginTop: 70,
  },
});
