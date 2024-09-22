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
  const screenWidth = Dimensions.get("window").width;
  const screenHeight = Dimensions.get("window").height;

  const [loading, setLoading] = useState(true);
  const [name, setName] = useState("");
  const [avatarUrl, setAvatarUrl] = useState("");
  const [signingOut, setSigningOut] = useState(false);
  const [selectedTab, setSelectedTab] = useState("Account");
  const navigation = useNavigation();

  const set_user_id = useAppStore((state) => state.set_user_id);
  const user_id = useAppStore((state) => state.user_id);
  const clearAllAppState = useAppStore((state) => state.clearAllAppState);

  useEffect(() => {
    if (session && !user_id.startsWith("guest")) getProfile();
  }, [session, user_id]);

  async function getProfile() {
    try {
      setLoading(true);
      if (!session?.user) throw new Error("No user on the session!");

      const { data, error, status } = await supabase
        .from("profiles")
        .select(`name`)
        .eq("id", session?.user.id)
        .single();
      if (error && status !== 406) {
        throw error;
      }

      if (data) {
        set_user_id(session?.user.id);
        setName(data.name);
      }
    } catch (error) {
      if (error instanceof Error) {
        Alert.alert(error.message);
      }
    } finally {
      setLoading(false);
    }
  }

  async function updateProfile({ name, avatar_url }) {
    try {
      setLoading(true);
      if (!session?.user) throw new Error("No user on the session!");

      const updates = {
        id: session?.user.id,
        name,
        updated_at: new Date(),
      };

      const { error } = await supabase.from("profiles").upsert(updates);

      if (error) {
        throw error;
      }

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

  async function handleSignOut() {
    try {
      setSigningOut(true);
      const { error } = await supabase.auth.signOut();
      if (error) {
        throw error;
      }

      clearAllAppState();
      useAppStore.getState().set_user_id(null);

      // Log the user_id after a brief delay to allow state to update
      setTimeout(() => {
        const updatedUserId = useAppStore.getState().user_id;
        console.log("user id:", updatedUserId); // This should now log null
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
      setSigningOut(false);
    }
  }

  return (
    <View style={styles.container}>
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
                    onChangeText={(text) => setName(text)}
                    inputStyle={{ color: "white" }}
                    placeholderTextColor="white"
                  />
                </View>

                <View style={styles.verticallySpaced}>
                  <Button
                    title={loading ? "Loading ..." : "Update"}
                    onPress={() =>
                      updateProfile({ name, avatar_url: avatarUrl })
                    }
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
              //chnage in this code for both side
              <Button
                title={signingOut ? "Signing Out..." : "Sign Out"}
                type="clear"
                titleStyle={{
                  color: "gray",
                  fontWeight: "bold",
                }}
                onPress={handleSignOut}
                disabled={signingOut}
              />
            )}
            {signingOut && <ActivityIndicator size="small" color="red" />}
          </View>
        </View>
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
