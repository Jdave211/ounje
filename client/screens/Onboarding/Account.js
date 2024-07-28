import { useState, useEffect } from "react";
import { supabase } from "../../utils/supabase";
import {
  StyleSheet,
  View,
  Alert,
  ActivityIndicator,
  TouchableOpacity,
  Dimensions,
  ScrollView,
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
    <ScrollView contentContainerStyle={styles.scrollContainer}>
      <View
        style={[styles.container, { flex: 1, justifyContent: "space-between" }]}
      >
        <View style={{ flexDirection: "row", justifyContent: "flex-end" }}>
          <TouchableOpacity
            onPress={() => {
              navigation.navigate("Settings");
            }}
          >
            <Icon
              name="settings"
              type="material"
              color="#fff"
              containerStyle={{
                marginRight: screenWidth * 0.04, // Responsive margin
                paddingTop: screenHeight * 0.06, // Responsive padding
              }}
            />
          </TouchableOpacity>
        </View>
        <View style={styles.content}>
          <View style={[styles.verticallySpaced, styles.mt20]}>
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

              <View style={[styles.verticallySpaced]}>
                <Button
                  title={loading ? "Loading ..." : "Update"}
                  onPress={() => updateProfile({ name, avatar_url: avatarUrl })}
                  disabled={loading}
                  buttonStyle={{
                    backgroundColor: "#282C35",
                    borderRadius: 15,
                    paddingVertical: screenHeight * 0.015, // Responsive padding
                  }}
                />
              </View>
            </>
          )}
        </View>

        <View style={styles.verticallySpaced}>
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
                titleStyle={{ color: "red", fontWeight: "bold" }}
                onPress={handleSignOut}
                disabled={signingOut}
              />
            )}
            {signingOut && <ActivityIndicator size="small" color="red" />}
          </View>
        </View>
        <Toast />
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scrollContainer: {
    flexGrow: 1,
  },
  container: {
    padding: Dimensions.get("window").width * 0.03, // Responsive padding
    backgroundColor: "#121212",
  },
  content: {
    flex: 1,
    justifyContent: "center",
  },
  verticallySpaced: {
    paddingTop: Dimensions.get("window").height * 0.005, // Responsive padding
    paddingBottom: Dimensions.get("window").height * 0.03, // Responsive padding
    alignSelf: "stretch",
  },
  mt20: {
    marginTop: Dimensions.get("window").height * 0.025, // Responsive margin
  },
});
