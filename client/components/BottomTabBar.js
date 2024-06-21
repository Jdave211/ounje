import * as React from "react";
import { View, TouchableOpacity, StyleSheet, Text } from "react-native";
import {
  FontAwesome5,
  FontAwesome,
  MaterialIcons,
  MaterialCommunityIcons,
} from "@expo/vector-icons";
import {
  useNavigation,
  useRoute,
  useNavigationState,
} from "@react-navigation/native";

const BottomTabBar = () => {
  const navigation = useNavigation();
  const state = useNavigationState((state) => state);

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
      name: "Inventory",
      screenName: "Inventory",
      iconName: "inventory",
      iconComponent: MaterialIcons,
    },
    {
      name: "Calories",
      screenName: "Calories",
      iconName: "food-apple",
      iconComponent: MaterialCommunityIcons,
    },
    {
      name: "Profile",
      screenName: "Profile",
      iconName: "person",
      iconComponent: MaterialIcons,
    },
  ];

  const currentRouteName = state?.routes[state.index]?.name;

  const renderTab = (tab, size = 24) => {
    const isSelected = currentRouteName === tab.screenName;
    return (
      <TouchableOpacity
        key={tab.screenName}
        style={styles.tab}
        onPress={() => navigation.navigate(tab.screenName)}
      >
        {React.createElement(tab.iconComponent, {
          name: tab.iconName,
          size,
          color: isSelected ? "#4cbb17" : "white",
        })}
        <Text
          style={{
            color: isSelected ? "#4cbb17" : "white",
            fontSize: 10,
            fontWeight: "bold",
          }}
        >
          {tab.name}
        </Text>
      </TouchableOpacity>
    );
  };

  return (
    <View style={styles.tabBar}>
      <View style={styles.tabs}>{tabs.map((tab) => renderTab(tab))}</View>
    </View>
  );
};

const styles = StyleSheet.create({
  tabBar: {
    backgroundColor: "#282C35",
    paddingTop: 15,
    paddingBottom: 25,
    borderTopColor: "#282C35",
    borderTopWidth: 1,
    position: "absolute",
    left: 0,
    right: 0,
    bottom: 0,
    width: "100%",
  },
  tabs: {
    flexDirection: "row",
    justifyContent: "space-around",
    paddingHorizontal: 10,
  },
  tab: {
    justifyContent: "center",
    alignItems: "center",
  },
});

export default BottomTabBar;
