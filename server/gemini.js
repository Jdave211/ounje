import fs from 'fs';
import dotenv from 'dotenv';
import express from 'express';
import bodyParser from 'body-parser';
import { GoogleGenerativeAI } from '@google/generative-ai';
import cors from 'cors';
dotenv.config();

const app = express();
app.use(bodyParser.json({ limit: '50mb' }));
app.use(bodyParser.urlencoded({ limit: '50mb', extended: true }));

// Load API key from environment variable
const apiKey = 'AIzaSyCFiJJRATlPXYhH7dzmmtDUhXcXzLz2J94';
if (!apiKey) {
  throw new Error('API_KEY environment variable not set.');
}

const genAI = new GoogleGenerativeAI(apiKey);

// Convert base64 data to GoogleGenerativeAI.Part object
function base64ToGenerativePart(base64Data, mimeType) {
  return {
    inlineData: {
      data: base64Data,
      mimeType
    },
  };
}

app.post('/', express.json(), async (req, res) => {
  try {
    const { prompt, images } = req.body;
    const model = genAI.getGenerativeModel({ model: "gemini-1.5-pro-latest" });
    const imageParts = images.map((base64Data) => base64ToGenerativePart(base64Data, 'image/jpeg'));

    const result = await model.generateContent([prompt, ...imageParts]);
    const response = await result.response;
    const text = await response.text();

    res.json({ result: text });
  } catch (error) {
    console.error("Error in API call:", error);
    res.status(500).json({ error: 'An error occurred' });
  }
});

const port = process.env.PORT || 8080;
app.listen(port, () => {
  console.log(`Server listening on port ${port}`);
});

