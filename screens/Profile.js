import 'react-native-url-polyfill/auto'
import { useState, useEffect } from 'react'
import { supabase } from '../utils/supabase'
import Auth from '../components/Auth'
import Account from '../components/Account'
import { View } from 'react-native'

export default function App() {
  const [session, setSession] = useState(null)

  useEffect(() => {
    const currentSession = supabase.auth.session();
    setSession(currentSession);

    const { data: authListener } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session);
    });

    return () => {
      authListener.unsubscribe();
    };
  }, []);

  return (
    <View>
      {session && session.user ? <Account key={session.user.id} session={session} /> : <Auth />}
    </View>
  )
}