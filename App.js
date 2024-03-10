import { StatusBar } from 'expo-status-bar';
import { StyleSheet, Text, View } from 'react-native';
import Layout from './_layout';
import Generate from './screens/Generate';

export default function App() {
  return (
    <View style={styles.container}>
      <Layout>
        <Generate/>
      </Layout>
      <StatusBar style="light" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
  },
  text: {
    fontSize: 20,
    color: 'white',
    textAlign: 'center',
  },
});
