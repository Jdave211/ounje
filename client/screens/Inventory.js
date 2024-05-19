import React, { useState, useEffect } from 'react';
import { View, Text, StyleSheet, ScrollView } from 'react-native';
import { CheckBox } from 'react-native-elements';
import { MultipleSelectList } from 'react-native-dropdown-select-list'
import { FontAwesome5 } from '@expo/vector-icons';
import RecipeCard from '../components/RecipeCard';

const Inventory = () => {
  const [selectedItems, setSelectedItems] = useState({});
  const [selected, setSelected] = useState([]);
  const [isDropdownOpen, setIsDropdownOpen] = useState(false);
  const [emojiData, setEmojiData] = useState(null);

  const food = 
    {
      "refrigerator": {
        "freezer_section": [
          { "name": "frozen meats", "quantity": 3 },
          { "name": "frozen vegetables", "quantity": 2 },
          { "name": "ice packs", "quantity": 1 }
        ],
        "main_section": [
          { "name": "yogurt", "quantity": 2 },
          { "name": "cheese blocks", "quantity": 2 },
          { "name": "orange juice", "quantity": 1 },
          { "name": "tomato sauce bottle", "quantity": 1 },
          { "name": "cold cuts", "quantity": 1 },
          { "name": "slices of cheese", "quantity": 1 }
        ],
        "crisper_drawer": [
          { "name": "apples", "quantity": 3 },
          { "name": "avocado", "quantity": 1 },
          { "name": "citrus fruits", "quantity": 3 }
        ],
        "door": [
          { "name": "beers", "quantity": 9 },
          { "name": "soda cans", "quantity": 3 },
          { "name": "bottled beverages", "quantity": 3 }
        ]
      },
      "pantry": {
        "top_shelf": [
          { "name": "applesauce jar", "quantity": 1 },
          { "name": "pickled vegetables jar", "quantity": 1 },
          { "name": "corn can", "quantity": 1 },
          { "name": "green beans can", "quantity": 1 },
          { "name": "tomato can", "quantity": 1 },
          { "name": "carrot jar", "quantity": 1 },
          { "name": "baby potatoes jar", "quantity": 1 }
        ],
        "middle_shelf": [
          { "name": "instant noodles", "quantity": 5 },
          { "name": "spaghetti can", "quantity": 1 },
          { "name": "soups can", "quantity": 5 },
          { "name": "canned meats", "quantity": 6 }
        ],
        "bottom_shelf": [
          { "name": "canned vegetables", "quantity": 7 },
          { "name": "packaged pasta", "quantity": 3 },
          { "name": "instant meals", "quantity": 4 },
          { "name": "tomato sauce cans", "quantity": 2 },
          { "name": "snack packets", "quantity": 3 },
          { "name": "sausages jars", "quantity": 3 }
        ]
      }
    }
    const handleCheck = (section, item) => {
      setSelectedItems(prevState => ({
        ...prevState,
        [section]: {
          ...prevState[section],
          [item.name]: !prevState[section]?.[item.name]
        }
      }));
    };
  

    // useEffect(() => {
    //   const options = {
    //     method: 'GET',
    //     url: 'https://emoji-ai.p.rapidapi.com/getEmoji',
    //     headers: {
    //       'X-RapidAPI-Key': '',
    //       'X-RapidAPI-Host': 'emoji-ai.p.rapidapi.com'
    //     }
    //   };
    
    //   Object.entries(food).forEach(([section, items]) => {
    //     Object.entries(items).forEach(([shelf, shelfItems]) => {
    //       shelfItems.forEach(item => {
    //         axios.request({
    //           ...options,
    //           params: { query: item.name }
    //         })
    //         .then(response => {
    //           setEmojiData(prevState => ({
    //             ...prevState,
    //             [item.name]: response.data
    //           }));
    //         })
    //         .catch(error => {
    //           console.error(error);
    //         });
    //       });
    //     });
    //   });
    // }, []);

    const mapFoodData = (sectionFilter) => {
      return Object.entries(food).flatMap(([section, items]) =>
        sectionFilter(section)
          ? Object.entries(items).flatMap(([shelf, shelfItems]) =>
              shelfItems.map(item => ({
                key: `${section}-${shelf}-${item.name}`,
                value: `${item.name}`
              }))
            )
          : []
      );
    };
    
    const data1 = mapFoodData(() => true);
    const data2 = mapFoodData(section => section === 'pantry');
  
    return (
      <ScrollView style={styles.container}>
        <MultipleSelectList
          setSelected={setSelected}
          selectedTextStyle={styles.selectedTextStyle}
          dropdownTextStyles={{color: 'white'}}
          data={data1}
          save="value"
          maxHeight={900}
          placeholder="Fridge"
          pla
          arrowicon={<FontAwesome5 name="chevron-down" size={12} color={'black'} />}
          searchicon={<FontAwesome5 name="search" size={12} color={'white'} />}
          searchPlaceholder="Search..."
          search={false}
          boxStyles={{marginTop:25, marginBottom:25, borderColor: 'white'}}
          label="Fridge"
          labelStyles={{color: 'green', fontSize: 20, fontWeight: 'bold'}}
          badgeStyles={{backgroundColor: 'green'}}
        />
        <MultipleSelectList
          setSelected={setSelected}
          data={data2}
          save="value"
          dropdownTextStyles={{color: 'white'}}
          maxHeight={900}
          placeholder="Pantry"
          arrowicon={<FontAwesome5 name="chevron-down" size={12} color={'black'} />} 
          searchicon={<FontAwesome5 name="search" size={12} color={'white'} />} 
          searchPlaceholder="Search..."
          search={false}
          boxStyles={{marginTop:2, marginBottom:25, borderColor: 'white'}}
          checkBoxStyles={{borderColor: 'green', color: 'green', back}}
          label="Pantry"
          labelStyles={{color: 'green', fontSize: 20, fontWeight: 'bold'}}
          badgeStyles={{backgroundColor: 'green'}}
        />
      </ScrollView>
    );
  };
  
  const styles = StyleSheet.create({
    container: {
      flex: 1,
      backgroundColor: 'black',
    },
    eachsection: {
      margin: 10,
    },
    text: {
      color: 'white',
    },
    selectedTextStyle: {
      color: 'blue',
      fontSize: 16,
    },
    inputSearchStyle: {
      color: 'white',
      backgroundColor: 'black',
    },
    title: {
      fontSize: 25,
      color: 'green',
      marginBottom: 20,
    },
    item: {
      flexDirection: 'row',
      alignItems: 'center',
    },
  });

export default Inventory;