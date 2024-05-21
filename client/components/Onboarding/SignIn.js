import React, { useState } from 'react';
import { Alert, StyleSheet, View, Text } from 'react-native';
import { supabase } from '../../utils/supabase';
import { Button, Input } from 'react-native-elements';

export default function SignIn() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);

  async function signInWithEmail() {
    setLoading(true);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) Alert.alert(error.message);
    setLoading(false);
  }

  return (
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
            onChangeText={(text) => setPassword(text)}
            value={password}
            secureTextEntry={true}
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
            onPress={() => Alert.alert('Forgot password')}
            />
        </View>
      </View>
    </View>
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