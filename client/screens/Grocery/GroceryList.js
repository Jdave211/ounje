// import { StyleSheet, Text, View, TextInput, FlatList, TouchableOpacity, Dimensions } from "react-native";
// import React, { useEffect, useState } from "react";
// import AsyncStorage from '@react-native-async-storage/async-storage';
// import IngredientCard from "../../components/IngredientCard";
// import Empty from "../../components/Empty";
// import { supabase } from "../../utils/supabase";
// import Checkbox from 'expo-checkbox';

// const screenWidth = Dimensions.get("window").width;

// const GroceryList = () => {
//   const [newItem, setNewItem] = useState('');
//   const [foodItems, setFoodItems] = useState([]);
//   const [checkedItems, setCheckedItems] = useState(new Set());

//   // Fetch food items based on item name
//   const fetchFoodItems = async (itemName) => {
//     const { data, error } = await supabase
//       .from('food_items_grocery')
//       .select('*')
//       .ilike('name', `%${itemName}%`);

//     if (error) {
//       console.error('Error fetching food items:', error);
//       return [];
//     }

//     return data;
//   };

//   // Function to add a new item to the grocery list
//   const addNewItem = async () => {
//     if (newItem.trim() === '') return;

//     const existingItems = await fetchFoodItems(newItem);
//     let newItemsList = [...foodItems];

//     if (existingItems.length > 0) {
//       newItemsList = [...newItemsList, ...existingItems];
//     } else {
//       const newItemData = { id: Date.now(), name: newItem, image: null };
//       const { error } = await supabase.from('food_items_grocery').insert([newItemData]);

//       if (!error) {
//         newItemsList.push(newItemData);
//       }
//     }

//     setFoodItems(newItemsList);
//     await AsyncStorage.setItem('groceryItems', JSON.stringify(newItemsList)); // Persist all items
//     setNewItem('');
//   };

//   // Function to handle item check/uncheck
//   const handleCheckItem = (itemId) => {
//     setCheckedItems((prevChecked) => {
//       const newChecked = new Set(prevChecked);
//       if (newChecked.has(itemId)) {
//         newChecked.delete(itemId);
//       } else {
//         newChecked.add(itemId);
//       }
//       return newChecked;
//     });
//   };

//   // Load items from AsyncStorage when the component mounts
//   useEffect(() => {
//     const loadItems = async () => {
//       try {
//         const storedItems = await AsyncStorage.getItem('groceryItems');
//         if (storedItems) {
//           const items = JSON.parse(storedItems);
//           setFoodItems(items);
//         }
//       } catch (error) {
//         console.error("Failed to load grocery items:", error);
//       }
//     };

//     loadItems();
//   }, []);

//   // Function to persist checked items to AsyncStorage
//   const persistCheckedItems = async () => {
//     const itemsToStore = foodItems.filter(item => !checkedItems.has(item.id));
//     await AsyncStorage.setItem('groceryItems', JSON.stringify(itemsToStore));
//   };

//   useEffect(() => {
//     persistCheckedItems();
//   }, [checkedItems]);

//   return (
//     <View style={styles.container}>
//       <Text style={styles.header}>Grocery List</Text>
//       <View style={styles.card}>
//         <Text style={styles.cardTitle}>Add New Food Item</Text>
//         <View style={styles.inputContainer}>
//           <TextInput
//             style={styles.input}
//             placeholder="Enter your food item"
//             placeholderTextColor="gray"
//             autoCapitalize="none"
//             maxLength={50}
//             value={newItem}
//             onChangeText={setNewItem}
//           />
//           <TouchableOpacity style={styles.addButton} onPress={addNewItem}>
//             <Text style={styles.buttonText}>Add</Text>
//           </TouchableOpacity>
//         </View>
//       </View>

//       <View style={styles.centeredContainer}>
//         {foodItems.length === 0 ? (
//           <View style={{ flex: 2, justifyContent: "center", alignContent: "center" }}>
//             <Empty />
//             <Text style={styles.warning}>
//               Your grocery list is empty. Add some items to get started.
//             </Text>
//           </View>
//         ) : (
//           <FlatList
//             data={foodItems.filter(item => !checkedItems.has(item.id))}
//             keyExtractor={(item) => item.id ? item.id.toString() : `key-${Math.random()}`}
//             renderItem={({ item }) => (
//               <View style={{ flexDirection: "row", alignItems: "center", marginBottom: 10, gap: 10 }}>
//                 <Checkbox
//                   value={checkedItems.has(item.id)}
//                   onValueChange={() => handleCheckItem(item.id)}
//                 />
//                 <View style={{ width: 90, marginRight: 10 }}>
//                   <IngredientCard
//                     name={item.name}
//                     image={item.image ? `https://img.spoonacular.com/ingredients_100x100/${item.image}` : null}
//                     GroceryItem={true}
//                   />
//                 </View>
//               </View>
//             )}
//           />
//         )}
//       </View>
//     </View>
//   );
// };

// export default GroceryList;

// const styles = StyleSheet.create({
//   container: {
//     padding: 20,
//   },
//   header: {
//     color: '#ffff',
//     fontSize: 24,
//     fontWeight: 'bold',
//     marginBottom: 10,
//   },
//   input: {
//     flex: 1,
//     height: 50,
//     borderColor: "white",
//     borderWidth: 1,
//     padding: 10,
//     borderRadius: 10,
//     color: "#fff",
//     backgroundColor: "#333",
//   },
//   addButton: {
//     marginLeft: 10,
//     backgroundColor: "#282C35",
//     borderRadius: 5,
//     padding: 10,
//   },
//   buttonText: {
//     color: "white",
//     fontWeight: "bold",
//   },
//   centeredContainer: {
//     flexDirection: "row",
//     flexWrap: "wrap",
//     justifyContent: "center",
//     alignItems: "center",
//   },
//   warning: {
//     color: '#fff',
//     textAlign: 'center',
//   },
//   card: {
//     backgroundColor: "#1f1f1f",
//     borderRadius: 10,
//     padding: 20,
//     marginBottom: 20,
//   },
//   cardTitle: {
//     color: "#fff",
//     fontSize: screenWidth * 0.045,
//     fontWeight: "bold",
//     marginBottom: 10,
//   },
//   inputContainer: {
//     flexDirection: "row",
//     alignItems: "center",
//     marginBottom: 10,
//   },
// });

import { StyleSheet, Text, View, TextInput, FlatList, TouchableOpacity, Dimensions } from "react-native";
import React, { useEffect, useState } from "react";
import AsyncStorage from '@react-native-async-storage/async-storage';
import IngredientCard from "../../components/IngredientCard";
import Empty from "../../components/Empty";
import { supabase } from "../../utils/supabase";
import Checkbox from 'expo-checkbox';

const screenWidth = Dimensions.get("window").width;

const GroceryList = () => {
  const [newItem, setNewItem] = useState('');
  const [foodItems, setFoodItems] = useState([]);
  const [checkedItems, setCheckedItems] = useState(new Set());

  // Fetch food items based on item name
  const fetchFoodItems = async (itemName) => {
    const { data, error } = await supabase
      .from('food_items_grocery')
      .select('*')
      .ilike('name', `%${itemName}%`);

    if (error) {
      console.error('Error fetching food items:', error);
      return [];
    }

    return data;
  };

  // Function to add a new item to the grocery list
  const addNewItem = async () => {
    if (newItem.trim() === '') return;

    const existingItems = await fetchFoodItems(newItem);
    let newItemsList = [...foodItems];

    if (existingItems.length > 0) {
      newItemsList = [...newItemsList, ...existingItems];
    } else {
      const newItemData = { id: Date.now(), name: newItem, image: null };
      const { error } = await supabase.from('food_items_grocery').insert([newItemData]);

      if (!error) {
        newItemsList.push(newItemData);
      }
    }

    setFoodItems(newItemsList);
    await AsyncStorage.setItem('groceryItems', JSON.stringify(newItemsList)); // Persist all items
    setNewItem('');
  };

  // Function to handle item check/uncheck
  const handleCheckItem = (itemId) => {
    setCheckedItems((prevChecked) => {
      const newChecked = new Set(prevChecked);
      if (newChecked.has(itemId)) {
        newChecked.delete(itemId);
      } else {
        newChecked.add(itemId);
      }
      return newChecked;
    });
  };

  // Load items from AsyncStorage when the component mounts
  useEffect(() => {
    const loadItems = async () => {
      try {
        const storedItems = await AsyncStorage.getItem('groceryItems');
        if (storedItems) {
          const items = JSON.parse(storedItems);
          setFoodItems(items);
        }
      } catch (error) {
        console.error("Failed to load grocery items:", error);
      }
    };

    loadItems();
  }, []);

  // Function to persist checked items to AsyncStorage
  const persistCheckedItems = async () => {
    const itemsToStore = foodItems.filter(item => !checkedItems.has(item.id));
    await AsyncStorage.setItem('groceryItems', JSON.stringify(itemsToStore));
  };

  useEffect(() => {
    persistCheckedItems();
  }, [checkedItems]);

  return (
    <View style={styles.container}>
      <Text style={styles.header}>Grocery List</Text>
      <View style={styles.card}>
        <Text style={styles.cardTitle}>Add New grocery Item</Text>
        <View style={styles.inputContainer}>
          <TextInput
            style={styles.input}
            placeholder="Enter your grocery item"
            placeholderTextColor="gray"
            autoCapitalize="none"
            maxLength={50}
            value={newItem}
            onChangeText={setNewItem}
          />
          <TouchableOpacity style={styles.addButton} onPress={addNewItem}>
            <Text style={styles.buttonText}>Add</Text>
          </TouchableOpacity>
        </View>
      </View>

      <View style={styles.centeredContainer}>
        {foodItems.length === 0 ? (
          <View style={{ flex: 2, justifyContent: "center", alignContent: "center" }}>
            <Empty />
            <Text style={styles.warning}>
              Your grocery list is empty. Add some items to get started.
            </Text>
          </View>
        ) : (
          <FlatList
            data={foodItems.filter(item => !checkedItems.has(item.id))}
            keyExtractor={(item) => item.id ? item.id.toString() : `key-${Math.random()}`}
            renderItem={({ item }) => (
              <View style={{ flexDirection: "row", alignItems: "center", marginBottom: 10, gap: 20 }}>
                <Checkbox
                  value={checkedItems.has(item.id)}
                  onValueChange={() => handleCheckItem(item.id)}
                />
                <View style={{ width: 90, marginRight: 10 }}>
                  <IngredientCard
                    name={item.name}
                    image={item.image ? `https://img.spoonacular.com/ingredients_100x100/${item.image}` : null}
                    GroceryItem={true}
                  />
                </View>
              </View>
            )}
          />
        )}
      </View>
    </View>
  );
};

export default GroceryList;

const styles = StyleSheet.create({
  container: {
    padding: 20,
  },
  header: {
    color: '#ffff',
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 10,
  },
  input: {
    flex: 1,
    height: 50,
    borderColor: "white",
    borderWidth: 1,
    padding: 10,
    borderRadius: 10,
    color: "#fff",
    backgroundColor: "#333",
  },
  addButton: {
    marginLeft: 10,
    backgroundColor: "#282C35",
    borderRadius: 5,
    padding: 10,
  },
  buttonText: {
    color: "white",
    fontWeight: "bold",
  },
  centeredContainer: {
    flexDirection: "row",
    flexWrap: "wrap",
    justifyContent: "center",
    alignItems: "center",
  },
  warning: {
    color: '#fff',
    textAlign: 'center',
  },
  card: {
    backgroundColor: "#1f1f1f",
    borderRadius: 10,
    padding: 20,
    marginBottom: 20,
  },
  cardTitle: {
    color: "#fff",
    fontSize: screenWidth * 0.045,
    fontWeight: "bold",
    marginBottom: 10,
  },
  inputContainer: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 10,
  },
});







