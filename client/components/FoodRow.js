import React, { useState, useEffect, useCallback } from "react";
import {
  View,
  Text,
  ScrollView,
  Image,
  StyleSheet,
  Dimensions,
} from "react-native";
import { Extrapolate, interpolate } from "react-native-reanimated";

import { supabase } from "../utils/supabase";
import Carousel from "react-native-reanimated-carousel";
import jrice from "../assets/jrice.png";
import bowl2 from "../assets/bowl2.png";
import pasta from "../assets/pasta.png";
import pancakes from "../assets/pancakes.png";
import silicon from "../assets/silicon.png";
import combination from "../assets/combination.png";
import toast from "../assets/toast.png";

import { parallaxLayout } from "../utils/parallax";

const FoodRow = () => {
  const [food_images, set_food_images] = useState([]);

  useEffect(() => {
    let recipe_bucket_paths = [
      "Veggie Stir-Fry/28.jpeg",
      "Tofu Stir-Fry/22.jpeg",
      "Simple Chicken Salad/26.jpeg",
    ];

    const fetch_food_images = async () => {
      const { data: retrieved_images, error } = await supabase
        .from("recipes") // Replace with your bucket name
        .select("image_url");

      console.log({ retrieved_images });

      let image_urls = retrieved_images.map((response, i) => ({
        id: i,
        src: response.image_url,
      }));

      set_food_images(() => image_urls);
    };

    fetch_food_images();
  }, []);

  const foods = [
    { id: 1, src: jrice },
    { id: 4, src: pancakes },
    { id: 3, src: silicon },
  ];

  const scale_fade_in_out = useCallback((value) => {
    "worklet";

    const zIndex = interpolate(value, [-1, 0, 1], [10, 20, 30]);
    const scale = interpolate(value, [-1, 0, 1], [1.25, 1, 0.25]);
    const opacity = interpolate(value, [-0.75, 0, 1], [0, 1, 0]);

    return {
      transform: [{ scale }],
      zIndex,
      opacity,
    };
  }, []);

  const PAGE_WIDTH = Dimensions.get("window").width;
  const HEIGHT = 180;
  // const baseOptions = {
  //     vertical: false,
  //     width: PAGE_WIDTH,
  //     height: PAGE_HEIGHT,
  //   } as const;
  const ITEM_WIDTH = PAGE_WIDTH * 0.3;
  return (
    <ScrollView horizontal={true} showsHorizontalScrollIndicator={false}>
      <Carousel
        loop
        pagingEnabled={false}
        snapEnabled={false}
        width={PAGE_WIDTH * 0.7}
        height={HEIGHT}
        style={{
          width: PAGE_WIDTH,
          height: HEIGHT,
          justifyContent: "center",
          alignItems: "center",
        }}
        // withAnimation={{
        //   type: "spring",
        //   config: {
        //     damping: 13,
        //   },
        // }}
        vertical={false}
        autoPlay={true}
        data={[...new Array(food_images.length).keys()]}
        scrollAnimationDuration={3000}
        customAnimation={parallaxLayout({
          size: ITEM_WIDTH,
        })}
        // onSnapToItem={(index) => console.log("current index:", index)}
        renderItem={({ index }) => {
          return (
            // <Text style={{ textAlign: "center", fontSize: 30 }}>{index}</Text>
            <View key={food_images[index].id} style={styles.imageContainer}>
              <Image
                source={{ uri: food_images[index].src }}
                style={styles.image}
                resizeMode="contain"
              />
            </View>
          );
        }}
      />
    </ScrollView>
  );
};

const styles = StyleSheet.create({
  imageContainer: {
    width: 130, // Adjust as needed
    // marginRight: 4, // Adjust as needed
  },
  image: {
    borderRadius: 10,
    width: "100%",
    height: 130, // Adjust as needed
  },
  text: {
    color: "white",
    textAlign: "center",
  },
});

export default FoodRow;
