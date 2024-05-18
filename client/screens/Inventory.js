import React, { useState } from 'react';
import { View, Text, StyleSheet, ScrollView } from 'react-native';
import { CheckBox } from 'react-native-elements';
import axios from 'axios';

const Inventory = () => {
  const [selectedItems, setSelectedItems] = useState({});
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
      "pantry_cupboard": {
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
  

    useEffect(() => {
      const options = {
        method: 'GET',
        url: 'https://emoji-ai.p.rapidapi.com/getEmoji',
        headers: {
          'X-RapidAPI-Key': '',
          'X-RapidAPI-Host': 'emoji-ai.p.rapidapi.com'
        }
      };
    
      Object.entries(food).forEach(([section, items]) => {
        Object.entries(items).forEach(([shelf, shelfItems]) => {
          shelfItems.forEach(item => {
            axios.request({
              ...options,
              params: { query: item.name }
            })
            .then(response => {
              setEmojiData(prevState => ({
                ...prevState,
                [item.name]: response.data
              }));
            })
            .catch(error => {
              console.error(error);
            });
          });
        });
      });
    }, []);

    return (
      <ScrollView style={styles.container}>
        <View style={styles.eachsection}>
        {Object.entries(food).map(([section, items]) => (
          <View key={section}>
            <Text style={[styles.text, styles.title]}>{section}</Text>
            {Object.entries(items).map(([shelf, shelfItems]) => (
              <View key={shelf}>
                <Text style={styles.text}>{shelf}</Text>
                {shelfItems.map(item => (
                  <View key={item.name} style={styles.item}>
                    <CheckBox
                      value={selectedItems[section]?.[item.name] || false}
                      onValueChange={() => handleCheck(section, item)}
                    />
                    <Text style={styles.text}>{item.name}</Text>
                  </View>
                ))}
              </View>
            ))}
          </View>
        ))}
        </View>
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