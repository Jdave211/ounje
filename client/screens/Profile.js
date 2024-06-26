import { useState, useEffect } from "react";
import { supabase } from "../utils/supabase"; // Import your Supabase client (optional)
import Account from "../screens/Onboarding/Account";
import { View, StyleSheet, Text } from "react-native";

export default function Profile() {
  const [session, setSession] = useState(null); // Optional: Keep session for other purposes

  useEffect(() => {
    const subscription = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session);
    });
    if (subscription.unsubscribe) {
      return () => subscription.unsubscribe();
    }
  }, []);

  return (
    <View style={styles.container}>
      <Account session={session} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "black",
  },
});
