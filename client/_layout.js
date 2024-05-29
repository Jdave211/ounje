import * as React from 'react';
import { View, Text, StyleSheet } from 'react-native';
import BottomTabBar from './components/BottomTabBar';

const Layout = ({ children }) => {
    return (
        <View style={styles.container}>
            <View style={styles.header}>
                <Text style={styles.headerText}>Oúnje</Text>
            </View>
            <View style={styles.content}>
                {children} 
            </View>
            <BottomTabBar/>
        </View>
    );
};

const styles = StyleSheet.create({
    container: {
        flex: 1,
        backgroundColor: 'black'
    },
    header: {
        paddingTop: 40,
        height: 80,
        justifyContent: 'center',
        alignItems: 'center',
        zIndex: 100,
    },
    headerText: {
        fontSize: 20,
        fontWeight: 'bold',
        color: 'white',
        textAlign: 'center',
    },
    content: {
        flex: 1,
    }
});

export default Layout;
