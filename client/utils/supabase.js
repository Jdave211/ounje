import "react-native-url-polyfill/auto";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { createClient } from "@supabase/supabase-js";

const supabaseUrl = "https://kmvqftoebsmmkhxrgdye.supabase.co";
const supabaseAnonKey =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImttdnFmdG9lYnNtbWtoeHJnZHllIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MTU3NDIxMzcsImV4cCI6MjAzMTMxODEzN30.l3Tbzuyjw7jXGfIxG6_NJc5zsUn1CHV13H3yBs0VsM0";

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    storage: AsyncStorage,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});

export const store_image = async (bucket, image_path, image) => {
  let { data: response, error } = await supabase.storage
    .from(bucket)
    .upload(image_path, image);

  if (error) throw new Error(error);

  return response;
};
