import { useState, useEffect } from "react";
import { supabase } from "../../utils/supabase";
import { StyleSheet, View, Alert } from "react-native";
import { Button, Input } from "react-native-elements";
import AsyncStorage from "@react-native-async-storage/async-storage";


export default function Account({ session }) {
  const [loading, setLoading] = useState(true);
  const [name, setName] = useState("");
  const [avatarUrl, setAvatarUrl] = useState("");

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
        await AsyncStorage.setItem("user_id", session?.user.id);
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

  return (
    <View
      style={[styles.container, { flex: 1, justifyContent: "space-between" }]}
    >
      <View>
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

        <View style={[styles.verticallySpaced, styles.mt20]}>
          <Button
            title={loading ? "Loading ..." : "Update"}
            onPress={() => updateProfile({ name, avatar_url: avatarUrl })}
            disabled={loading}
            buttonStyle={{ backgroundColor: "green" }}
          />
        </View>
      </View>

      <View style={styles.verticallySpaced}>
        <View style={{ alignItems: "center" }}>
          <Button
            title="Sign Out"
            type="clear"
            titleStyle={{ color: "red" }}
            onPress={() => supabase.auth.signOut()}
          />
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    marginTop: 40,
    padding: 12,
    backgroundColor: "black",
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
