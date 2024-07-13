import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  SectionList,
  StyleSheet,
  Linking,
  Alert,
  ActivityIndicator,
} from "react-native";
import { Icon, Button } from "react-native-elements";
import { supabase } from "../../utils/supabase";
import Toast from "react-native-toast-message";
import { useAppStore } from "../../stores/app-store";
import { useNavigation } from "@react-navigation/native";

const settingsData = [
  {
    category: "Account",
    data: [
      {
        id: "1",
        title: "Subscribe to Premium",
        description: "Unlock all premium features by subscribing.",
        icon: "star",
        screen: "PremiumSubscription",
      },
    ],
  },
  {
    category: "Support",
    data: [
      {
        id: "2",
        title: "Help Center",
        description: "Get help and support.",
        icon: "help",
        screen: "https://ounje.net/partnership",
      },
      {
        id: "3",
        title: "Send Feedback",
        description: "Send us your feedback.",
        icon: "feedback",
        screen: "https://tally.so/r/mZdrez",
      },
    ],
  },
  {
    category: "Legal",
    data: [
      {
        id: "4",
        title: "Privacy Policy",
        description: "Read our privacy policy.",
        icon: "privacy-tip",
        screen: "https://ounje.net/privacy",
      },
      {
        id: "5",
        title: "Terms of Service",
        description: "Review the terms of service.",
        icon: "gavel",
        screen: "https://ounje.net/termsofservice",
      },
    ],
  },
];

const SettingsScreen = ({ navigation }) => {
  const [deleteAcc, setDeleteAcc] = useState(false);
  const clearAllAppState = useAppStore((state) => state.clearAllAppState);
  const user_id = useAppStore((state) => state.user_id);

  const handlePress = (screen) => {
    if (screen.startsWith("http")) {
      Linking.openURL(screen);
    } else {
      navigation.navigate(screen);
    }
  };

  const handleDeleteAccount = () => {
    Alert.alert(
      "Confirm Delete",
      "Are you sure you want to delete your account? This action cannot be undone.",
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Delete",
          style: "destructive",
          onPress: async () => {
            setDeleteAcc(true);
            try {
              // Sign out logic
              const { error: signOutError } = await supabase.auth.signOut();
              if (signOutError) {
                throw signOutError;
              }

              // Delete account logic
              const { error: deleteError } = await supabase
                .from("profiles")
                .delete()
                .eq("id", user_id);

              if (deleteError) {
                throw deleteError;
              }

              clearAllAppState();

              Toast.show({
                type: "success",
                text1: "Account Deleted",
                text2: "Your account has been successfully deleted.",
              });

              navigation.navigate("Login"); // Navigate to the login screen
            } catch (error) {
              Alert.alert("Error", error.message);
            } finally {
              setDeleteAcc(false);
            }
          },
        },
      ],
    );
  };

  const renderItem = ({ item }) => (
    <TouchableOpacity
      style={[
        styles.item,
        item.title === "Subscribe to Premium" && styles.glow,
      ]}
      onPress={() => handlePress(item.screen)}
    >
      <View style={styles.iconContainer}>
        <Icon name={item.icon} type="material" color="#fff" />
      </View>
      <View style={styles.textContainer}>
        <Text style={styles.title}>{item.title}</Text>
        <Text style={styles.description}>{item.description}</Text>
      </View>
    </TouchableOpacity>
  );

  const renderSectionHeader = ({ section: { category } }) => (
    <Text style={styles.categoryTitle}>{category}</Text>
  );

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity onPress={() => navigation.goBack()}>
          <Icon name="arrow-back" type="material" color="#fff" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>Settings</Text>
      </View>
      <SectionList
        sections={settingsData}
        keyExtractor={(item) => item.id}
        renderItem={renderItem}
        renderSectionHeader={renderSectionHeader}
        contentContainerStyle={styles.listContainer}
      />
      <View style={styles.deleteContainer}>
        <Button
          title={deleteAcc ? "Deleting Account..." : "Delete Account"}
          type="clear"
          titleStyle={{ color: "red", fontSize: 16, fontWeight: "bold" }}
          onPress={handleDeleteAccount}
          disabled={deleteAcc}
          buttonStyle={styles.deleteButton}
        />
        {deleteAcc && <ActivityIndicator size="small" color="red" />}
      </View>
      <Toast />
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#121212",
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
  categoryTitle: {
    color: "#fff",
    fontSize: 22,
    marginLeft: 16,
    marginBottom: 10,
    marginTop: 20,
  },
  deleteContainer: {
    padding: 10,
    marginBottom: 15,
  },
  deleteButton: {
    borderWidth: 0,
  },
  glow: {
    shadowColor: "gray", // Green glow effect
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 1,
    shadowRadius: 10,
    elevation: 10, // Adds shadow for Android
  },
});

export default SettingsScreen;
