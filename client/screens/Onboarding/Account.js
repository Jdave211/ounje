import { useState, useEffect } from "react";
import { supabase } from "../../utils/supabase";
import {
  StyleSheet,
  View,
  Alert,
  Image,
  ActivityIndicator,
} from "react-native";
import { Button, Input } from "react-native-elements";
import { FontAwesome6 } from "@expo/vector-icons";
import Toast from "react-native-toast-message";
import { useAppStore } from "@stores/app-store";

export default function Account({ session }) {
  const [loading, setLoading] = useState(true);
  const [name, setName] = useState("");
  const [avatarUrl, setAvatarUrl] = useState("");
  const [signingOut, setSigningOut] = useState(false);
  const [deleteAcc, setDelete] = useState(false);

  const set_user_id = useAppStore((state) => state.set_user_id);
  const user_id = useAppStore((state) => state.user_id);
  const clearAllAppState = useAppStore((state) => state.clearAllAppState);

  useEffect(() => {
    if (session) getProfile();
  }, [session]);

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
    } catch (error) {
      if (error instanceof Error) {
        Alert.alert(error.message);
      }
    } finally {
      setLoading(false);
    }
  }

  async function handleDeleteAccount() {
    //function to actually delete an account
    try {
      setDeleteAcc(true);
      await handleSignOut();

      const { error } = await supabase
        .from("profiles")
        .delete()
        .eq("id", user_id);

      if (error) {
        throw error;
      }

      Toast.show({
        type: "success",
        text1: "Account Deleted",
        text2: "Your account has been successfully deleted.",
      });
    } catch (error) {
      if (error instanceof Error) {
        Alert.alert(error.message);
      }
    } finally {
      setDeleteAcc(false);
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
    <View
      style={[styles.container, { flex: 1, justifyContent: "space-between" }]}
    >
      <View style={styles.content}>
        <View style={[styles.verticallySpaced, styles.mt20]}>
          <Input
            label="Email"
            value={session?.user?.email}
            disabled
            inputStyle={{ color: "white" }} // Add this line
            placeholderTextColor="white" // Add this line
          />
        </View>
        <View style={styles.verticallySpaced}>
          <Input
            label="Name"
            value={name || ""}
            onChangeText={(text) => setName(text)}
            inputStyle={{ color: "white" }} // Add this line
            placeholderTextColor="white" // Add this line
          />
        </View>

        <View style={[styles.verticallySpaced]}>
          <Button
            title={loading ? "Loading ..." : "Update"}
            onPress={() => updateProfile({ name, avatar_url: avatarUrl })}
            disabled={loading}
            buttonStyle={{ backgroundColor: "#282C35", borderRadius: 15 }}
          />
        </View>
      </View>

      <View style={styles.verticallySpaced}>
        <View style={{ alignItems: "center" }}>
          <Button
            title={signingOut ? "Signing Out..." : "Sign Out"}
            type="clear"
            titleStyle={{ color: "red" }}
            onPress={handleSignOut}
            disabled={signingOut}
          />
          {signingOut && <ActivityIndicator size="small" color="red" />}
          <Button
            title={deleteAcc ? "Deleting Account..." : "Delete Account"}
            type="clear"
            titleStyle={{ color: "red" }}
            onPress={handleSignOut}
            disabled={deleteAcc}
          />
          {deleteAcc && <ActivityIndicator size="small" color="red" />}
        </View>
      </View>
      <Toast />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    padding: 12,
    backgroundColor: "#121212",
  },
  content: {
    flex: 1,
    justifyContent: "center",
  },
  verticallySpaced: {
    paddingTop: 4,
    paddingBottom: 25,
    alignSelf: "stretch",
  },
  mt20: {
    marginTop: 20,
  },
});
