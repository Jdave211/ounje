// import React, { useEffect, useState } from "react";
// import { StyleSheet, View, FlatList, ActivityIndicator } from "react-native";
// import RecipeCard from "./RecipeCard";
// import LoadingScreen from "./Loading";

// const DiscoverRecipes = () => {
//   const [recipes, setRecipes] = useState([]);
//   const [loading, setLoading] = useState(true);
//   const [fetchCount, setFetchCount] = useState(0); // Counter to ensure unique keys

//   useEffect(() => {
//     fetchRandomRecipes();
//   }, []);

//   const fetchRandomRecipes = async () => {
//     try {
//       const response = await fetch(
//         "https://www.themealdb.com/api/json/v1/1/random.php"
//       );
//       const data = await response.json();

//       const newRecipe = data.meals[0]; // Assume the response has only one meal
//       const recipeExists = recipes.some(recipe => recipe.idMeal === newRecipe.idMeal);

//       if (!recipeExists) {
//         // If it does not exist, add it to the recipes state with a unique key
//         setRecipes(prevRecipes => [
//           ...prevRecipes,
//           { ...newRecipe, uniqueKey: `${newRecipe.idMeal}-${fetchCount}` } // Append fetchCount to ensure uniqueness
//         ]);
//         setFetchCount(prevCount => prevCount + 1); // Increment the fetch count
//         setLoading(true)
//       }
//     } catch (error) {
//       console.error("Error fetching recipes:", error);
//     } finally {
//       setLoading(false);
//     }
//   };

//   return (
//     <View style={styles.container}>
//       {loading ? (
//         // <ActivityIndicator size="large" color="green" />
//         <LoadingScreen />
//       ) : (
//         <FlatList
//   data={recipes}
//   keyExtractor={(item) => item.uniqueKey} // Use the unique key
//   renderItem={({ item }) => (
//     <RecipeCard
//       id={item.idMeal}
//       title={item.strMeal}
//       imageUrl={item.strMealThumb}
//       readyInMinutes={item.readyInMinutes || (item.strCookingTime ? parseInt(item.strCookingTime) : 30)} // Adjust accordingly
//     />
//   )}
//   onEndReached={fetchRandomRecipes}
//   onEndReachedThreshold={0.5}
// />
//       )}
//     </View>
//   );
// };

// export default DiscoverRecipes;

// const styles = StyleSheet.create({
//   container: {
//     flexGrow: 1,
//     // padding: 16,
//     // backgroundColor: '#fff',
//   },
// });

import React, { useEffect, useState } from "react";
import { StyleSheet, View, FlatList, ActivityIndicator } from "react-native";
import RecipeCard from "./RecipeCard";
import LoadingScreen from "./Loading";

const DiscoverRecipes = () => {
  const [recipes, setRecipes] = useState([]);
  const [loading, setLoading] = useState(false);
  const [fetchCount, setFetchCount] = useState(0); // Counter to ensure unique keys

  useEffect(() => {
    fetchRandomRecipes();
  }, []);

  const fetchRandomRecipes = async () => {
    try {
      setLoading(true); // Set loading to true before fetching
      const response = await fetch(
        "https://www.themealdb.com/api/json/v1/1/random.php"
      );
      const data = await response.json();

      const newRecipe = data.meals[0]; // Assume the response has only one meal
      const recipeExists = recipes.some(recipe => recipe.idMeal === newRecipe.idMeal);

      if (!recipeExists) {
        // If it does not exist, add it to the recipes state with a unique key
        setRecipes(prevRecipes => [
          ...prevRecipes,
          { ...newRecipe, uniqueKey: `${newRecipe.idMeal}-${fetchCount}` } // Append fetchCount to ensure uniqueness
        ]);
        setFetchCount(prevCount => prevCount + 1); // Increment the fetch count
      }
    } catch (error) {
      console.error("Error fetching recipes:", error);
    } finally {
      setLoading(false); // Set loading to false after fetching
    }
  };

  return (
    <View style={styles.container}>
      <FlatList
        data={recipes}
        keyExtractor={(item) => item.uniqueKey} // Use the unique key
        renderItem={({ item }) => (
          <RecipeCard
            id={item.idMeal}
            title={item.strMeal}
            imageUrl={item.strMealThumb}
            readyInMinutes={item.readyInMinutes || (item.strCookingTime ? parseInt(item.strCookingTime) : 30)} // Adjust accordingly
          />
        )}
        onEndReached={fetchRandomRecipes}
        onEndReachedThreshold={0.5}
        ListFooterComponent={loading && <ActivityIndicator size="large" color="green" />} // Optional footer loading indicator
        contentContainerStyle={loading ? { paddingBottom: 100 } : {}} // Extra padding to avoid content cut-off
      />
    </View>
  );
};

export default DiscoverRecipes;

const styles = StyleSheet.create({
  container: {
    flexGrow: 1,
    // padding: 16,
    // backgroundColor: '#fff',
  },
});
