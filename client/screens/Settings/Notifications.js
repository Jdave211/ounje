import React from "react";
import {
  View,
  Text,
  TouchableOpacity,
  FlatList,
  StyleSheet,
} from "react-native";
import { Icon } from "react-native-elements";

const notificationsData = [
  {
    id: "1",
    title: "Limited Lifetime Offer",
    description: "The first 5,000 users will get lifetime access at a discounted rate.",
    icon: "new-releases",
  },
  {
    id: "2",
    title: "Subscription Renewal",
    description: "Your subscription has been successfully renewed.",
    icon: "autorenew",
  },
  {
    id: "3",
    title: "Account Update",
    description: "Your account details have been updated.",
    icon: "account-circle",
  },
  {
    id: "4",
    title: "Promotion",
    description: "Get 20% off on your next purchase.",
    icon: "local-offer",
  },
];

export default function NotificationsScreen({ navigation }) {
  const renderItem = ({ item }) => (
    <TouchableOpacity style={styles.item}>
      <View style={styles.iconContainer}>
        <Icon name={item.icon} type="material" color="#fff" />
      </View>
      <View style={styles.textContainer}>
        <Text style={styles.title}>{item.title}</Text>
        <Text style={styles.description}>{item.description}</Text>
      </View>
    </TouchableOpacity>
  );

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity onPress={() => navigation.goBack()}>
          <Icon name="arrow-back" type="material" color="#fff" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>Notifications</Text>
      </View>
      <FlatList
        data={notificationsData}
        renderItem={renderItem}
        keyExtractor={(item) => item.id}
        contentContainerStyle={styles.listContainer}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#121212",
    padding: 5,
    paddingTop: 40,
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    padding: 16,
    borderBottomWidth: 1,
    borderBottomColor: "#333",
  },
  headerTitle: {
    color: "#fff",
    fontSize: 20,
    marginLeft: 16,
  },
  listContainer: {
    padding: 16,
  },
  item: {
    flexDirection: "row",
    alignItems: "center",
    paddingVertical: 16,
    borderBottomWidth: 1,
    borderBottomColor: "#333",
  },
  iconContainer: {
    marginRight: 16,
  },
  textContainer: {
    flex: 1,
  },
  title: {
    color: "#fff",
    fontSize: 18,
  },
  description: {
    color: "#888",
    marginTop: 4,
  },
});
