import OpenAi from "openai";

const openai = new OpenAi({
    apiKey: process.env.EXPO_PUBLIC_OPENAI_API_KEY,
});
  

export default openai;