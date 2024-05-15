import React, { useState } from 'react' 
import { Alert, StyleSheet, View, AppState } from 'react-native' 
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
        if (!data.session) Alert.alert('Please check your inbox for email verification!')     
        setLoading(false)   
      }    
      
      import 'react-native-url-polyfill/auto'
import { useState, useEffect } from 'react'
import { supabase } from '../utils/supabase'
import Auth from '../components/Auth'
import Account from '../components/Account'
import { View, StyleSheet } from 'react-native'

export default function Profile() {
  const [session, setSession] = useState(null)

  useEffect(() => {
    const getSession = async () => {
      const { data: { session }, error } = await supabase.auth.getSession();
      if (error) {
        console.error("Error fetching session:", error);
        return;
      }
      setSession(session);
    };
  
    getSession();
  
    const subscription = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session);
    });
  
    return () => subscription.unsubscribe();
  }, []);
  

  return (
    <View style={styles.container}>
      {session && session.user ? <Account key={session.user.id} session={session} /> : <Auth />}
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: 'black',
  },
});