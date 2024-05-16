import React, { useState } from 'react' 
import { Alert, StyleSheet, View, AppState, Text } from 'react-native' 
import { supabase } from '../utils/supabase' 
import { Button, Input } from 'react-native-elements'  

AppState.addEventListener('change', (state) => {   
  if (state === 'active') {     
    supabase.auth.startAutoRefresh()   
  } else {     
    supabase.auth.stopAutoRefresh()   } 
  })  
  
    export default function Auth() {   
      const [email, setEmail] = useState('')   
      const [password, setPassword] = useState('')   
      const [loading, setLoading] = useState(false)    
      
      async function signInWithEmail() {     
        setLoading(true)     
        const { error } = await supabase.auth.signInWithPassword({       email,       password,     })     
        if (error) Alert.alert(error.message)     
        setLoading(false)   
      }    
      
      async function signUpWithEmail() {     
        setLoading(true)     
        const { data, error } = await supabase.auth.signUp({       email,       password,     })     
        if (error) Alert.alert(error.message)
        setLoading(false)   
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
              autoCapitalize={'none'}
              inputStyle={{ color: 'white' }} // Add this line
              placeholderTextColor='gray' // Add this line
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
              autoCapitalize={'none'}
              inputStyle={{ color: 'white' }} // Add this line
              placeholderTextColor='gray' // Add this line
            />
          </View>
          <View style={[styles.verticallySpaced, styles.mt20]}>
          <Button 
            title="Sign in" 
            disabled={loading} 
            onPress={() => signInWithEmail()} 
            buttonStyle={{ backgroundColor: 'green' }} // Add this line
          />          
          </View>
          <View style={styles.verticallySpaced}>
          <Button 
            title="Sign up" 
            disabled={loading} 
            onPress={() => signUpWithEmail()} 
            buttonStyle={{ backgroundColor: 'green' }} // Add this line
          />
          </View>
          </View>
        </View>
      )
    }
    
    const styles = StyleSheet.create({
      container: {
        marginTop: -12,
        padding: 12,
      },
      header: {
        paddingTop: 58,
        height: 100,
        justifyContent: 'center',
        alignItems: 'center',
        zIndex: 100,
        marginBottom: 20,
      },
      headerText: {
        fontSize: 20,
        fontWeight: 'bold',
        color: 'white',
        textAlign: 'center',
      },
      body: {
        justifyContent: 'center',
        alignItems: 'center',
        marginTop: 120,
      },
      verticallySpaced: {
        paddingTop: 4,
        paddingBottom: 4,
        alignSelf: 'stretch',
      },
      mt20: {
        marginTop: 20,
      },
    })    // ... (the same JSX as in the TypeScript version)   ) } 