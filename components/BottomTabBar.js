import * as React from 'react';
import { View, TouchableOpacity, StyleSheet } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { FontAwesome5 } from '@expo/vector-icons';
import { Entypo } from '@expo/vector-icons';
import { MaterialIcons } from '@expo/vector-icons';
import { useNavigation } from '@react-navigation/native';

const BottomTabBar = () => {
    const [selectedTab, setSelectedTab] = React.useState('dna');

    const renderIcon = (name, iconComponent, size = 24) => (
        <TouchableOpacity 
            style={selectedTab === name ? styles.selectedIcon : null} 
            // onPress={() => setSelectedTab(name)} 
            >
            {React.createElement(iconComponent, { name, size, color: 'white' })}
        </TouchableOpacity>
    );

    return (
        <View style={styles.tabBar}>
            {renderIcon('dna', FontAwesome5, 25)}
            {renderIcon('scroll', FontAwesome5, 25)}
            {renderIcon('cloud', Entypo, 25)}
            {renderIcon('person', MaterialIcons, 25)}
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