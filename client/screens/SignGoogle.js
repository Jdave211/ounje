// IOS ID: 664933805905-0uk9jgs2a171a1c9nde505pj01bu9p8i.apps.googleusercontent.com
// import React, { useEffect, useState } from 'react';
// import { Button, Platform, StyleSheet, Text, View } from 'react-native';
// import * as Google from 'expo-auth-session/providers/google';
// import * as WebBrowser from 'expo-web-browser';
// import * as AuthSession from 'expo-auth-session';

// WebBrowser.maybeCompleteAuthSession();

// export default function App() {
//   const [userInfo, setUserInfo] = useState(null);

//   const [request, response, promptAsync] = Google.useIdTokenAuthRequest({
//     clientId: '664933805905-0uk9jgs2a171a1c9nde505pj01bu9p8i.apps.googleusercontent.com',
//   });

//   useEffect(() => {
//     if (response?.type === 'success') {
//       const { id_token } = response.params;
//       getUserInfo(id_token);
//     }
//   }, [response]);

//   const getUserInfo = async (token) => {
//     const response = await fetch('https://www.googleapis.com/userinfo/v2/me', {
//       headers: { Authorization: `Bearer ${token}` },
//     });

//     const user = await response.json();
//     setUserInfo(user);
//   };

//   return (
//     <View style={styles.container}>
//       <Text style={styles.header}>Google Sign In</Text>
//       {userInfo ? (
//         <View>
//           <Text>Welcome, {userInfo.name}</Text>
//           <Text>{userInfo.email}</Text>
//         </View>
//       ) : (
//         <Button
//           disabled={!request}
//           title="Login with Google"
//           onPress={() => {
//             promptAsync();
//           }}
//         />
//       )}
//     </View>
//   );
// }

// const styles = StyleSheet.create({
//   container: {
//     flex: 1,
//     justifyContent: 'center',
//     alignItems: 'center',
//   },
//   header: {
//     fontSize: 20,
//     marginBottom: 20,
//   },
// });

import React, { useEffect, useState } from 'react';
import { Button, StyleSheet, Text, View } from 'react-native';
import * as Google from 'expo-auth-session/providers/google';

export default function SignGoogle() {
  const [userInfo, setUserInfo] = useState(null);

  const [request, response, promptAsync] = Google.useAuthRequest({
    expoClientId: 'brianmbaji/ounje', // Replace with your Expo username/appslug
    iosClientId: '664933805905-0uk9jgs2a171a1c9nde505pj01bu9p8i.apps.googleusercontent.com', // Replace with your actual iOS client ID
    redirectUri: 'https://auth.expo.io/brianmbaji/ounje', // Replace with your actual redirect URI
  });

  useEffect(() => {
    console.log('Request:', request);
    console.log('Response:', response);

    if (response?.type === 'success') {
      const { authentication } = response;
      console.log('Authentication:', authentication);
      getUserInfo(authentication.accessToken);
    }
  }, [response]);

  const getUserInfo = async (token) => {
    const response = await fetch('https://www.googleapis.com/userinfo/v2/me', {
      headers: { Authorization: `Bearer ${token}` },
    });

    const user = await response.json();
    setUserInfo(user);
  };

  return (
    <View style={styles.container}>
      <Text style={styles.header}>Google Sign In</Text>
      {userInfo ? (
        <View>
          <Text>Welcome, {userInfo.name}</Text>
          <Text>{userInfo.email}</Text>
        </View>
      ) : (
        <Button
          disabled={!request}
          title="Login with Google"
          onPress={() => {
            promptAsync();
          }}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  header: {
    fontSize: 20,
    marginBottom: 20,
  },
});
