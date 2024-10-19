// import React, { useState } from "react";
// import { View, Text, StyleSheet, Image, TouchableOpacity } from "react-native";
// import { Feather, MaterialIcons } from "@expo/vector-icons";
// import Toast from "react-native-toast-message";
// import { supabase } from "../utils/supabase";
// import { Bar as ProgressBar } from "react-native-progress";
// import { useAppStore } from "../stores/app-store";
// import { useQuery } from "react-query";
// import { fetchRecipeDetails } from "../utils/spoonacular";
// import { fetchIsRecipeSavedByUser } from "../utils/supabase";
// import { usePercentageOfIngredientsOwned } from "../hooks/usePercentageOfIngredientsOwned";

// const RecipeCard = ({
//   id: recipe_id,
//   showBookmark,
//   title,
//   summary,
//   imageUrl,
//   readyInMinutes,
//   onUnsave,
//   servings,
//   calories,
// }) => {
//   const [isRecipeSaved, setIsRecipeSaved] = useState(false);

//   const user_id = useAppStore((state) => state.user_id);

//   // Fetch recipe details based on recipe_id
//   const { data: recipeDetails } = useQuery(
//     ["recipeDetails", recipe_id],
//     async () => await fetchRecipeDetails(recipe_id) //fetch recipe details
//   );

//   // Check if the recipe is already saved by the user
//   useQuery(
//     ["isRecipeSaved", user_id],
//     async () => await fetchIsRecipeSavedByUser(user_id, recipe_id), // check if the recipe is saved
//     {
//       onSuccess: (isAlreadySaved) => {
//         // On successful fetch
//         if (isAlreadySaved) setIsRecipeSaved(true); // Update state if the recipe is already saved
//       },
//     }
//   );

//   // Get the percentage of ingredients owned for the recipe
//   const percentage = usePercentageOfIngredientsOwned(recipeDetails);

//   // Function to handle saving or unsaving a recipe
//   const handleSave = async () => {
//     let shouldSave = !isRecipeSaved; // Determine whether to save or unsave

//     setIsRecipeSaved(shouldSave); // Update state

//     if (shouldSave) {
//       // If saving the recipe
//       await supabase
//         .from("saved_recipes")
//         .insert([
//           // Insert the recipe into the saved_recipes table
//           {
//             user_id,
//             recipe_id: recipeDetails ? recipeDetails.id : recipe_id,
//           },
//         ])
//         .throwOnError(); // Handle errors

//       Toast.show({
//         // Show success toast
//         type: "success",
//         text1: "Recipe Saved",
//         text2: `${
//           title || recipeDetails.title
//         } has been saved to your recipes.`,
//       });
//       // If recipe is not saved, return null
//       if (!isRecipeSaved) {
//         return null; // Prevent rendering of this component if the recipe is not saved
//       }

//       return;
//     } else {
//       //   await supabase
//       //     .from("saved_recipes")
//       //     .delete()
//       //     .eq("user_id", user_id)
//       //     .eq("recipe_id", recipeDetails ? recipeDetails.id : recipe_id)
//       //     .throwOnError();
//       //   Toast.show({
//       //     type: "success",
//       //     text1: "Recipe Unsaved",
//       //     text2: `${
//       //       title || recipeDetails.title
//       //     } has been removed from your saved recipes.`,
//       //   });

//       //   if (onUnsave) {
//       //   onUnsave(recipe_id);
//       // }

//       // Call handleUnsaveRecipe to remove the recipe from saved recipes
//       await handleUnsaveRecipe(recipeDetails ? recipeDetails.id : recipe_id);
//     }
//   };

//   // Function to handle unsaving a recipe
//   const handleUnsaveRecipe = async (recipe_id) => {
//     try {
//       await supabase
//         .from("saved_recipes")
//         .delete() // Delete the recipe from saved_recipes table
//         .eq("user_id", user_id)
//         .eq("recipe_id", recipe_id)
//         .throwOnError(); // Handle errors

//       Toast.show({
//         type: "success",
//         text1: "Recipe Unsaved",
//         text2: `${
//           title || recipeDetails.title
//         } has been removed from your saved recipes.`,
//       });

//       if (onUnsave) {
//         // Call onUnsave callback if provided
//         onUnsave(recipe_id);
//       }
//     } catch (error) {
//       console.error("Error unsaving recipe:", error); // Log any errors
//     }
//   };

//   return (
//     <View style={styles.container}>
//       {recipeDetails || title ? (
//         <View style={styles.card}>
//           <Image
//             style={styles.image}
//             source={{ uri: imageUrl || recipeDetails?.image }}
//           />
//           <View style={styles.cardContent}>
//             <Text style={styles.title} numberOfLines={2}>
//               {title || recipeDetails.title}
//             </Text>
//             <View style={styles.detailsContainer}>
//               <View style={styles.detailItem}>
//                 <Feather name="clock" size={16} color="#8A8A8A" />
//                 <Text style={styles.detailText}>
//                   {readyInMinutes || recipeDetails.ready_in_minutes} mins
//                 </Text>
//               </View>
//             </View>
//             <View style={styles.progressContainer}>
//               <Text style={styles.detailText}>
//                 {new Number(percentage).toFixed(0)}% of Ingredients
//               </Text>
//               <ProgressBar
//                 color="white"
//                 progress={percentage / 100}
//                 width={80}
//                 style={styles.progressBar}
//               />
//             </View>
//             {showBookmark && (
//               <TouchableOpacity style={styles.saveButton} onPress={handleSave}>
//                 <MaterialIcons
//                   name={isRecipeSaved ? "bookmark" : "bookmark-border"}
//                   size={24}
//                   color={isRecipeSaved ? "#38F096" : "#8A8A8A"}
//                 />
//                 <Text style={styles.saveButtonText}>
//                   {isRecipeSaved ? "Saved" : "Save"}
//                 </Text>
//               </TouchableOpacity>
//             )}
//           </View>
//         </View>
//       ) : null}
//     </View>
//   );
// };

// const styles = StyleSheet.create({
//   container: {
//     flex: 1,
//     marginBottom: 20,
//   },
//   card: {
//     borderRadius: 15,
//     backgroundColor: "#2E2E2E",
//     overflow: "hidden",
//     shadowColor: "#000",
//     shadowOffset: { width: 0, height: 2 },
//     shadowOpacity: 0.8,
//     shadowRadius: 5,
//     elevation: 5,
//   },
//   image: {
//     width: "100%",
//     height: 160,
//     borderTopLeftRadius: 15,
//     borderTopRightRadius: 15,
//   },
//   cardContent: {
//     padding: 15,
//   },
//   title: {
//     fontSize: 18,
//     fontWeight: "900",
//     color: "#FFFFFF",
//     marginBottom: 8,
//   },
//   detailsContainer: {
//     flexDirection: "row",
//     justifyContent: "space-between",
//     marginBottom: 15,
//   },
//   detailItem: {
//     flexDirection: "row",
//     alignItems: "center",
//   },
//   detailText: {
//     marginLeft: 5,
//     fontSize: 14,
//     fontWeight: "700",
//     color: "#8A8A8A",
//   },
//   progressContainer: {
//     flexDirection: "row",
//     alignItems: "center",
//     justifyContent: "center", // Center the progress section
//     marginBottom: 15,
//   },
//   progressBar: {
//     marginLeft: 10, // Spacing between text and progress bar
//   },
//   saveButton: {
//     flexDirection: "row",
//     alignItems: "center",
//     justifyContent: "center",
//     backgroundColor: "#383838",
//     padding: 8,
//     borderRadius: 8,
//     marginTop: 10,
//   },
//   saveButtonText: {
//     color: "#8A8A8A",
//     fontSize: 14,
//     marginLeft: 5,
//   },
// });

// export default RecipeCard;


import React, { useState, useEffect } from "react";
import { View, Text, StyleSheet, Image, TouchableOpacity } from "react-native";
import { Feather, MaterialIcons } from "@expo/vector-icons";
import Toast from "react-native-toast-message";
import { supabase } from "../utils/supabase";
import { Bar as ProgressBar } from "react-native-progress";
import { useAppStore } from "../stores/app-store";
import { useQuery } from "react-query";
import { fetchRecipeDetails } from "../utils/spoonacular";
import { fetchIsRecipeSavedByUser } from "../utils/supabase";
import { usePercentageOfIngredientsOwned } from "../hooks/usePercentageOfIngredientsOwned";

const RecipeCard = ({
  id: recipe_id,
  showBookmark,
  title,
  summary,
  imageUrl,
  readyInMinutes,
  onUnsave,
  servings,
  calories,
}) => {
  const [isRecipeSaved, setIsRecipeSaved] = useState(false);
  const user_id = useAppStore((state) => state.user_id);

  // Fetch recipe details based on recipe_id
  const { data: recipeDetails } = useQuery(
    ["recipeDetails", recipe_id],
    async () => await fetchRecipeDetails(recipe_id) //fetch recipe details
  );

  // Check if the recipe is already saved by the user
  const { data: isAlreadySaved } = useQuery(
    ["isRecipeSaved", user_id, recipe_id],
    async () => await fetchIsRecipeSavedByUser(user_id, recipe_id),
  );

  // Set initial state for isRecipeSaved
  useEffect(() => {
    if (isAlreadySaved) {
      setIsRecipeSaved(true);
    }
  }, [isAlreadySaved]);

  // Get the percentage of ingredients owned for the recipe
  const percentage = usePercentageOfIngredientsOwned(recipeDetails);

  // Function to handle saving or unsaving a recipe
  const handleSave = async () => {
    let shouldSave = !isRecipeSaved; // Determine whether to save or unsave

    if (shouldSave) {
      // If saving the recipe
      await supabase
        .from("saved_recipes")
        .insert([{
          user_id,
          recipe_id: recipeDetails ? recipeDetails.id : recipe_id,
        }])
        .throwOnError();

      Toast.show({
        type: "success",
        text1: "Recipe Saved",
        text2: `${title || recipeDetails.title} has been saved to your recipes.`,
      });

      setIsRecipeSaved(true); // Update state after successful save
    } else {
      // If unsaving the recipe
      await handleUnsaveRecipe(recipeDetails ? recipeDetails.id : recipe_id);
      setIsRecipeSaved(false); // Update state after successful unsave
    }
  };

  // Function to handle unsaving a recipe
  const handleUnsaveRecipe = async (recipe_id) => {
    try {
      await supabase
        .from("saved_recipes")
        .delete()
        .eq("user_id", user_id)
        .eq("recipe_id", recipe_id)
        .throwOnError();

      Toast.show({
        type: "success",
        text1: "Recipe Unsaved",
        text2: `${title || recipeDetails.title} has been removed from your saved recipes.`,
      });

      if (onUnsave) {
        onUnsave(recipe_id);
      }
    } catch (error) {
      console.error("Error unsaving recipe:", error);
    }
  };

  return (
    <View style={styles.container}>
      {recipeDetails || title ? (
        <View style={styles.card}>
          <Image
            style={styles.image}
            source={{ uri: imageUrl || recipeDetails?.image }}
          />
          <View style={styles.cardContent}>
            <Text style={styles.title} numberOfLines={2}>
              {title || recipeDetails.title}
            </Text>
            <View style={styles.detailsContainer}>
              <View style={styles.detailItem}>
                <Feather name="clock" size={16} color="#8A8A8A" />
                <Text style={styles.detailText}>
                  {readyInMinutes || recipeDetails.ready_in_minutes} mins
                </Text>
              </View>
            </View>
            <View style={styles.progressContainer}>
              <Text style={styles.detailText}>
                {new Number(percentage).toFixed(0)}% of Ingredients
              </Text>
              <ProgressBar
                color="white"
                progress={percentage / 100}
                width={80}
                style={styles.progressBar}
              />
            </View>
            {showBookmark && (
              <TouchableOpacity style={styles.saveButton} onPress={handleSave}>
                <MaterialIcons
                  name={isRecipeSaved ? "bookmark" : "bookmark-border"}
                  size={24}
                  color={isRecipeSaved ? "#38F096" : "#8A8A8A"}
                />
                <Text style={styles.saveButtonText}>
                  {isRecipeSaved ? "Saved" : "Save"}
                </Text>
              </TouchableOpacity>
            )}
          </View>
        </View>
      ) : null}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    marginBottom: 20,
  },
  card: {
    borderRadius: 15,
    backgroundColor: "#2E2E2E",
    overflow: "hidden",
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.8,
    shadowRadius: 5,
    elevation: 5,
  },
  image: {
    width: "100%",
    height: 160,
    borderTopLeftRadius: 15,
    borderTopRightRadius: 15,
  },
  cardContent: {
    padding: 15,
  },
  title: {
    fontSize: 18,
    fontWeight: "900",
    color: "#FFFFFF",
    marginBottom: 8,
  },
  detailsContainer: {
    flexDirection: "row",
    justifyContent: "space-between",
    marginBottom: 15,
  },
  detailItem: {
    flexDirection: "row",
    alignItems: "center",
  },
  detailText: {
    marginLeft: 5,
    fontSize: 14,
    fontWeight: "700",
    color: "#8A8A8A",
  },
  progressContainer: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 15,
  },
  progressBar: {
    marginLeft: 10,
  },
  saveButton: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: "#383838",
    padding: 8,
    borderRadius: 8,
    marginTop: 10,
  },
  saveButtonText: {
    color: "#8A8A8A",
    fontSize: 14,
    marginLeft: 5,
  },
});

export default RecipeCard;

