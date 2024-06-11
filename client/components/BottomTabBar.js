import * as React from "react";
import { View, TouchableOpacity, StyleSheet, Text } from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { FontAwesome5, FontAwesome, MaterialIcons } from "@expo/vector-icons";
import { Entypo } from "@expo/vector-icons";
import { useNavigation } from "@react-navigation/native";

const BottomTabBar = () => {
  const [selectedTab, setSelectedTab] = React.useState("Generate");
  const navigation = useNavigation();

  const tabs = [
    {
      name: "Home",
      screenName: "Home",
      iconName: "home",
      iconComponent: FontAwesome5,
    },
    {
      name: "Collection",
      screenName: "Collection",
      iconName: "bookmark",
      iconComponent: FontAwesome,
    },
    {
      name: "Community",
      screenName: "Community",
      iconName: "cloud",
      iconComponent: Entypo,
    },
    {
      name: "Inventory",
      screenName: "Inventory",
      iconName: "inventory",
      iconComponent: MaterialIcons,
    },
    {
      name: "Profile",
      screenName: "Profile",
      iconName: "person",
      iconComponent: MaterialIcons,
    },
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
      {React.createElement(tab.iconComponent, {
        name: tab.iconName,
        size,
        color: selectedTab === tab.screenName ? "#4cbb17" : "white",
      })}
    </TouchableOpacity>
  );

  return (
    <View style={styles.tabBar}>
      {tabs.map((tab) => (
        <View
          key={tab.name}
          style={{ justifyContent: "center", alignItems: "center" }}
        >
          {renderIcon(tab)}
          <Text style={{ color: "white" }}>{tab.name}</Text>
        </View>
      ))}
    </View>
  );
};

const styles = StyleSheet.create({
  tabBar: {
    flexDirection: "row",
    justifyContent: "space-around",
    backgroundColor: "#333",
    padding: 20,
    paddingBottom: 20,
    borderTopColor: "black",
    borderTopWidth: 1,
    position: "absolute",
    left: 0,
    right: 0,
    bottom: 0,
    width: "100%",
  },
});

export default BottomTabBar;
