import React, { useState } from "react";
import {
  Alert,
  StyleSheet,
  View,
  AppState,
  Text,
  TouchableWithoutFeedback,
  Keyboard,
} from "react-native";
import { supabase } from "../../utils/supabase";
import { Button, Input } from "react-native-elements";
import Loading from "../../components/Loading";
import { useNavigation } from "@react-navigation/native";

AppState.addEventListener("change", (state) => {
  if (state === "active") {
    supabase.auth.startAutoRefresh();
  } else {
    supabase.auth.stopAutoRefresh();
  }
});

export default function Auth() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [passwordVisible, setPasswordVisible] = useState(false);
  const [confirmPasswordVisible, setConfirmPasswordVisible] = useState(false);

  async function signUpWithEmail() {
    if (password !== confirmPassword) {
      Alert.alert("Passwords do not match");
      return;
    }

    setLoading(true);
    const {
      data: { session },
      error,
    } = await supabase.auth.signUp({
      email: email,
      password: password,
    });

    if (error) Alert.alert(error.message);
    else if (!session)
      Alert.alert("Please check your inbox for email verification to sign in!");
    setLoading(false);
  }

  const togglePasswordVisibility = () => {
    setPasswordVisible(!passwordVisible);
  };

  const toggleConfirmPasswordVisibility = () => {
    setConfirmPasswordVisible(!confirmPasswordVisible);
  };

  return (
    <TouchableWithoutFeedback onPress={Keyboard.dismiss}>
      <View style={styles.container}>
        <View style={styles.header}>
          <Text style={styles.headerText}>Oúnje</Text>
        </View>
        <View style={styles.body}>
          <View style={[styles.verticallySpaced, styles.mt20]}>
            <Input
              label="Email"
              leftIcon={{ type: "font-awesome", name: "envelope" }}
              onChangeText={(text) => setEmail(text)}
              value={email}
              placeholder="email@address.com"
              autoCapitalize={"none"}
              inputStyle={{ color: "white" }}
              placeholderTextColor="gray"
            />
          </View>
          <View style={styles.verticallySpaced}>
            <Input
              label="Password"
              leftIcon={{ type: "font-awesome", name: "lock" }}
              rightIcon={{
                type: "font-awesome",
                name: passwordVisible ? "eye-slash" : "eye",
                onPress: togglePasswordVisibility,
              }}
              onChangeText={(text) => setPassword(text)}
              value={password}
              secureTextEntry={!passwordVisible}
              placeholder="Password"
              autoCapitalize={"none"}
              inputStyle={{ color: "white" }}
              placeholderTextColor="gray"
            />
          </View>
          <View style={styles.verticallySpaced}>
            <Input
              label="Confirm Password"
              leftIcon={{ type: "font-awesome", name: "lock" }}
              rightIcon={{
                type: "font-awesome",
                name: confirmPasswordVisible ? "eye-slash" : "eye",
                onPress: toggleConfirmPasswordVisibility,
              }}
              onChangeText={(text) => setConfirmPassword(text)}
              value={confirmPassword}
              secureTextEntry={!confirmPasswordVisible}
              placeholder="Confirm Password"
              autoCapitalize={"none"}
              inputStyle={{ color: "white" }}
              placeholderTextColor="gray"
            />
          </View>
          <View style={[styles.verticallySpaced, styles.signupButton]}>
            <Button
              title="Sign up"
              disabled={loading}
              onPress={() => signUpWithEmail()}
              buttonStyle={{ backgroundColor: "green" }}
            />
          </View>
        </View>
      </View>
    </TouchableWithoutFeedback>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 12,
    justifyContent: "flex-start",
  },
  header: {
    zIndex: 100,
    marginBottom: 20,
    marginTop: 20,
  },
  headerText: {
    fontSize: 20,
    fontWeight: "bold",
    color: "white",
    textAlign: "center",
  },
  body: {},
  verticallySpaced: {
    paddingTop: 4,
    paddingBottom: 4,
    borderRadius: 10,
  },
  mt20: {
    marginTop: 20,
  },
  signupButton: {
    marginTop: 5,
  },
});
