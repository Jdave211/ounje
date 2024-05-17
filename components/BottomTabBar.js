import * as React from 'react';
import { View, TouchableOpacity, StyleSheet } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { FontAwesome5 } from '@expo/vector-icons';
import { Entypo } from '@expo/vector-icons';
import { MaterialIcons } from '@expo/vector-icons';
import { useNavigation } from '@react-navigation/native';

const BottomTabBar = () => {
    const [selectedTab, setSelectedTab] = React.useState('Generate');
    const navigation = useNavigation();

    const tabs = [
        { screenName: 'Generate', iconName: 'dna', iconComponent: FontAwesome5 },
        { screenName: 'SavedRecipes', iconName: 'scroll', iconComponent: FontAwesome5 },
        { screenName: 'Community', iconName: 'cloud', iconComponent: Entypo },
        { screenName: 'Inventory', iconName: 'inventory', iconComponent: MaterialIcons},
        { screenName: 'Profile', iconName: 'person', iconComponent: MaterialIcons },
    ];

    const renderIcon = (tab, size = 24) => (
        <TouchableOpacity 
            key={tab.screenName}
            style={selectedTab === tab.screenName ? styles.selectedIcon : null} 
            onPress={() => {
                setSelectedTab(tab.screenName);
                navigation.navigate(tab.screenName);
            }}
        >
            {React.createElement(tab.iconComponent, { name: tab.iconName, size, color: 'white' })}
        </TouchableOpacity>
    );

    return (
        <View style={styles.tabBar}>
            {tabs.map(tab => renderIcon(tab, 25))}
        </View>
    );
};

const styles = StyleSheet.create({
    tabBar: {
        flexDirection: 'row',
        justifyContent: 'space-around',
        backgroundColor: '#333',
        padding: 17,
        paddingBottom: 25,
        borderTopColor: 'black',
        borderTopWidth: 1,
        position: 'absolute',
        left: 0, 
        right: 0, 
        bottom: 0, 
        width: '100%',
    },
    selectedIcon: {
        backgroundColor: '#4cbb17',
        borderRadius: 20,
        padding: 11,
        shadowColor: '#4cbb17',
        shadowOffset: {
            width: 0,
            height: 1,
        },
        shadowOpacity: 0.8,
        shadowRadius: 3.84,
        elevation: 5,
    },
});

export default BottomTabBar;