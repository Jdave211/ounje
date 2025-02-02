import React, { useState, useEffect } from "react";
import { supabase } from "../../utils/supabase";
import {
  StyleSheet,
  View,
  Alert,
  ActivityIndicator,
  TouchableOpacity,
  Dimensions,
  ScrollView,
  Text,
} from "react-native";
import { Button, Input, Icon } from "react-native-elements";
import Toast from "react-native-toast-message";
import { useAppStore } from "../../stores/app-store";
import { useNavigation } from "@react-navigation/native";


export default function Account({ session }) {
  // State variables
  const [loading, setLoading] = useState(true); // Loading state for profile
  const [name, setName] = useState(""); // User name
  const [avatarUrl, setAvatarUrl] = useState(""); // Avatar URL
  const [signingOut, setSigningOut] = useState(false); // Signing out state
  const [selectedTab, setSelectedTab] = useState("Account"); // Tab selection state

  const navigation = useNavigation(); // Navigation object

  // Accessing app state from a store
  const set_user_id = useAppStore((state) => state.set_user_id);
  const user_id = useAppStore((state) => state.user_id);
  const clearAllAppState = useAppStore((state) => state.clearAllAppState);

  // Effect to fetch profile when session or user_id changes
  useEffect(() => {
    if (session && !user_id.startsWith("guest")) getProfile();
  }, [session, user_id]);

  // Function to fetch the user profile from Supabase
  async function getProfile() {
    try {
      setLoading(true); // Show loading spinner
      if (!session?.user) throw new Error("No user on the session!");

      const { data, error, status } = await supabase
        .from("profiles")
        .select("name")
        .eq("id", session?.user.id)
        .single();

      if (error && status !== 406) {
        throw error;
      }

      if (data) {
        set_user_id(session?.user.id); // Store the user ID in the app state
        setName(data.name); // Set the fetched name
      }
    } catch (error) {
      if (error instanceof Error) {
        Alert.alert(error.message); // Display error message
      }
    } finally {
      setLoading(false); // Hide loading spinner
    }
  }

  // Function to update the user profile
  async function updateProfile({ name, avatar_url }) {
    if (name.trim() !== "") {
      try {
        setLoading(true);
        if (!session?.user) throw new Error("No user on the session!");

        const updates = {
          id: session?.user.id,
          name,
          avatar_url,
          updated_at: new Date(), // Add updated timestamp
        };

        const { error } = await supabase.from("profiles").upsert(updates); // Update profile

        if (error) throw error;

        Toast.show({
          type: "success",
          text1: "Profile Updated",
          text2: "Your name has been updated successfully.",
        });
      } catch (error) {
        if (error instanceof Error) {
          Alert.alert(error.message);
        }
      } finally {
        setLoading(false);
      }
    }

  else {
    Alert.alert("Name cannot be empty!");
  }
}
  // Function to handle signing out
  async function handleSignOut() {
    try {
      setSigningOut(true); // Show signing out state
      const { error } = await supabase.auth.signOut(); // Sign out from Supabase

      if (error) throw error;

      clearAllAppState(); // Clear all app state on sign out
      useAppStore.getState().set_user_id(null); // Reset user_id to null

      setTimeout(() => {
        console.log("user id:", useAppStore.getState().user_id); // Log the updated user_id
      }, 500);

      Toast.show({
        type: "success",
        text1: "Signed out",
        text2: "You have successfully signed out.",
      });
    } catch (error) {
      if (error instanceof Error) {
        Alert.alert(error.message);
      }
    } finally {
      setSigningOut(false); // Hide signing out state
    }
  }

  return (
    <View style={styles.container}>
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.headerText}>Profile</Text>
        <Text style={styles.headerSubtext}>
          User preferences, restrictions, & more
        </Text>
        <TouchableOpacity
          style={styles.settingsButton}
          onPress={() => navigation.navigate("Settings")}
        >
          <Icon name="settings" type="material" color="#fff" />
        </TouchableOpacity>
      </View>

      {/* Segmented Control for switching tabs */}
      <View style={styles.segmentedControl}>
        <TouchableOpacity
          style={[
            styles.segmentButton,
            selectedTab === "Account" && styles.segmentButtonSelected,
          ]}
          onPress={() => setSelectedTab("Account")}
        >
          <Text
            style={[
              styles.segmentButtonText,
              selectedTab === "Account" && styles.segmentButtonTextSelected,
            ]}
          >
            Account
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[
            styles.segmentButton,
            selectedTab === "Preferences" && styles.segmentButtonSelected,
          ]}
          onPress={() => setSelectedTab("Preferences")}
        >
          <Text
            style={[
              styles.segmentButtonText,
              selectedTab === "Preferences" && styles.segmentButtonTextSelected,
            ]}
          >
            Preferences
          </Text>
        </TouchableOpacity>
      </View>

      {/* Main content */}
      <ScrollView contentContainerStyle={styles.scrollContainer}>
        {selectedTab === "Account" ? (
          <View style={styles.content}>
            <View style={styles.verticallySpaced}>
              <Input
                label="Email"
                value={session?.user?.email}
                disabled
                inputStyle={{ color: "white" }}
                placeholderTextColor="white"
              />
            </View>
            {!user_id.startsWith("guest") && (
              <>
                <View style={styles.verticallySpaced}>
                  <Input
                    label="Name"
                    value={name || ""}
                    onChangeText={setName}
                    inputStyle={{ color: "white" }}
                    placeholderTextColor="white"
                  />
                </View>

                <View style={styles.verticallySpaced}>
                  <Button
                    title={loading ? "Loading ..." : "Update"}
                    onPress={() => updateProfile({ name, avatar_url: avatarUrl })}
                    disabled={loading}
                    buttonStyle={styles.updateButton}
                  />
                </View>
              </>
            )}
          </View>
        ) : (
          <View style={styles.content}>
            <Text style={styles.headerText}>Dietary Restrictions</Text>
            <Text style={styles.text}>Details about dietary restrictions.</Text>
            <Text style={styles.headerText}>Preferences</Text>
            <Text style={styles.text}>User food preferences details.</Text>
          </View>
        )}

        {/* Sign Out / Log In Button */}
        <View style={styles.signOutContainer}>
          <View style={{ alignItems: "center" }}>
            {user_id.startsWith("guest") ? (
              <Button
                title={"Log In"}
                type="clear"
                titleStyle={{ color: "green", fontWeight: "bold" }}
                onPress={() => set_user_id(null)}
              />
            ) : (
              <Button
                title={signingOut ? "Signing Out..." : "Sign Out"}
                type="clear"
                titleStyle={{ color: "gray", fontWeight: "bold" }}
                onPress={handleSignOut}
                disabled={signingOut}
              />
            )}
            {signingOut && <ActivityIndicator size="small" color="red" />}
          </View>
        </View>

        {/* Toast Notification */}
        <Toast />
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  scrollContainer: {
    flexGrow: 1,
  },
  container: {
    padding: Dimensions.get("window").width * 0.03,
    backgroundColor: "#181818", // Slightly different background color
    flexGrow: 1,
  },
  header: {
    justifyContent: "flex-start",
    alignItems: "flex-start",
    marginBottom: Dimensions.get("window").height * 0.04,
    marginTop: Dimensions.get("window").height * 0.1,
    marginLeft: Dimensions.get("window").width * 0.03,
  },
  headerText: {
    color: "#e0e0e0", // Slightly different text color
    fontSize: 25,
    fontWeight: "bold",
  },
  headerSubtext: {
    color: "gray",
    fontSize: 16,
    marginTop: 5,
  },
  settingsButton: {
    position: "absolute",
    top: 10,
    right: 10,
  },
  segmentedControl: {
    flexDirection: "row",
    alignSelf: "stretch",
    marginBottom: 20,
    borderBottomWidth: 1,
    borderBottomColor: "#383838", // Slightly different border color
  },
  segmentButton: {
    flex: 1,
    paddingVertical: 10,
    alignItems: "center",
  },
  segmentButtonSelected: {
    borderBottomWidth: 2,
    borderBottomColor: "gray",
  },
  segmentButtonText: {
    color: "gray",
    fontSize: 16,
  },
  segmentButtonTextSelected: {
    color: "white",
    fontWeight: "bold",
  },
  content: {
    flex: 1,
    justifyContent: "center",
    marginTop: 20,
  },
  verticallySpaced: {
    marginVertical: 10,
    alignSelf: "stretch",
  },
  updateButton: {
    backgroundColor: "#383838", // Slightly different button color
    borderRadius: 15,
    paddingVertical: Dimensions.get("window").height * 0.015,
  },
  text: {
    color: "#e0e0e0", // Slightly different text color
    fontSize: 16,
    marginVertical: 10,
  },
  signOutContainer: {
    marginVertical: Dimensions.get("window").height * 0.05,
  },
});


