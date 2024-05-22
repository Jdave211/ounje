import React, { useState } from 'react';
import { Alert, StyleSheet, View, Text, TouchableWithoutFeedback, Keyboard } from 'react-native';
import { supabase } from '../../utils/supabase';
import { Button, Input } from 'react-native-elements';
import { Entypo } from '@expo/vector-icons';

export default function SignIn() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [passwordVisible, setPasswordVisible] = useState(false);
  const [firstLogin, setFirstLogin] = useState(false);

  async function signInWithEmail() {
    setLoading(true);
    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    setLoading(false);
    if (error) {
      Alert.alert(error.message);
    } else if (data.user) {
      const { data, error } = await supabase
        .from('users')
        .select(`user_metadata`)
        .eq('id', user.id)
        .single();

      if (error) {
        Alert.alert(error.message);
      } else if (data && Object.keys(data.user_metadata).length === 0) {
        setFirstLogin(true); // Set firstLogin to true if user_metadata is empty
      }
    }
  }

  async function handleForgotPassword() {
    const { error } = await supabase.auth.resetPasswordForEmail(email);
    if (error) {
      Alert.alert('Error sending password reset email', error.message);
    } else {
      Alert.alert('Password reset email sent', 'Please check your email for instructions to reset your password.');
    }
  }

  const togglePasswordVisibility = () => {
    setPasswordVisible(!passwordVisible);
  };

  if (firstLogin) {
    return <FirstLogin email={email} password={password} />;
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
              leftIcon={{ type: 'font-awesome', name: 'envelope' }}
              onChangeText={(text) => setEmail(text)}
              value={email}
              placeholder="email@address.com"
              autoCapitalize="none"
              inputStyle={{ color: 'white' }}
              placeholderTextColor="gray"
            />
          </View>
          <View style={styles.verticallySpaced}>
          <Input
            label="Password"
            leftIcon={{ type: 'font-awesome', name: 'lock' }}
            rightIcon={{ 
              type: 'font-awesome', 
              name: passwordVisible ? 'eye-slash' : 'eye',
              onPress: togglePasswordVisibility
            }}
            onChangeText={(text) => setPassword(text)}
            value={password}
            secureTextEntry={!passwordVisible}
            placeholder="Password"
            autoCapitalize="none"
            inputStyle={{ color: 'white' }}
            placeholderTextColor="gray"
          />
          </View>
          <View style={[styles.verticallySpaced, {flexDirection:'column'}]}>
            <Button
              title="Sign in"
              disabled={loading}
              onPress={signInWithEmail}
              buttonStyle={{ backgroundColor: 'green', height: 50}}
            />
            <Button
              title="Forgot password?"
              type="clear"
              buttonStyle={{ backgroundColor: 'transparent', marginTop: 10}}
              titleStyle={{ fontSize: 13, color: 'white'}}
              onPress={handleForgotPassword}
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
    justifyContent: 'flex-start',
  },
  header: {
    zIndex: 100,
    marginBottom: 20,
    marginTop: 20,
  },
  headerText: {
    fontSize: 20,
    fontWeight: 'bold',
    color: 'white',
    textAlign: 'center',
  },
  body: {},
  verticallySpaced: {
    paddingTop: 4,
    paddingBottom: 4,
  },
  mt20: {
    marginTop: 20,
  },
});