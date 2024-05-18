import { useState, useEffect } from 'react'
import { supabase } from '../utils/supabase'
import { StyleSheet, View, Alert } from 'react-native'
import { Button, Input } from 'react-native-elements'

export default function Account({ session }) {
  const [loading, setLoading] = useState(true)
  const [username, setUsername] = useState('')
  const [avatarUrl, setAvatarUrl] = useState('')

  useEffect(() => {
    if (session) getProfile()
  }, [session])

  async function getProfile() {
    try {
      setLoading(true)
      if (!session?.user) throw new Error('No user on the session!')

      const { data, error, status } = await supabase
        .from('profiles')
        .select(`username, avatar_url`)
        .eq('id', session?.user.id)
        .single()
      if (error && status !== 406) {
        throw error
      }

      if (data) {
        setUsername(data.username)
        setAvatarUrl(data.avatar_url)
      }
    } catch (error) {
      if (error instanceof Error) {
        Alert.alert(error.message)
      }
    } finally {
      setLoading(false)
    }
  }

  async function updateProfile({ username, avatar_url }) {
    try {
      setLoading(true)
      if (!session?.user) throw new Error('No user on the session!')

      const updates = {
        id: session?.user.id,
        username,
        avatar_url,
        updated_at: new Date(),
      }

      const { error } = await supabase.from('profiles').upsert(updates)

      if (error) {
        throw error
      }
    } catch (error) {
      if (error instanceof Error) {
        Alert.alert(error.message)
      }
    } finally {
      setLoading(false)
    }
  }

  return (
    <View style={[styles.container, { flex: 1, justifyContent: 'space-between' }]}>
        <View>
      <View style={[styles.verticallySpaced, styles.mt20]}>
        <Input 
          label="Email" 
          value={session?.user?.email} 
          disabled 
          inputStyle={{ color: 'white' }} // Add this line
          placeholderTextColor='white' // Add this line
        />
      </View>
      <View style={styles.verticallySpaced}>
        <Input 
          label="Username" 
          value={username || ''} 
          onChangeText={(text) => setUsername(text)} 
          inputStyle={{ color: 'white' }} // Add this line
          placeholderTextColor='white' // Add this line
        />
      </View>
  
      <View style={[styles.verticallySpaced, styles.mt20]}>
        <Button
          title={loading ? 'Loading ...' : 'Update'}
          onPress={() => updateProfile({ username, avatar_url: avatarUrl })}
          disabled={loading}
          buttonStyle={{ backgroundColor: 'green' }}
        />
      </View>
      </View>
  
      <View style={styles.verticallySpaced}>
      <View style={{ alignItems: 'center' }}>
        <Button 
            title="Sign Out" 
            type="clear"
            titleStyle={{ color: 'red' }}
            onPress={() => supabase.auth.signOut()} 
        />
        </View>
      </View>
    </View>
    )
}

const styles = StyleSheet.create({
  container: {
    marginTop: 40,
    padding: 12,
    backgroundColor: 'black',
  },
  verticallySpaced: {
    paddingTop: 4,
    paddingBottom: 4,
    alignSelf: 'stretch',
  },
  mt20: {
    marginTop: 20,
  },
})