const express = require('express');
import OpenAI from 'openai';
const cors = require('cors');

const app = express();
const port = 8080;

app.use(cors());
app.use(express.json());


const openai = new OpenAI({
    apiKey: process.env.OPENAI_API_KEY,
  });
  
app.get('/', async (req, res) => {
  try {
    const questionCompletion = await openai.chat.completions.create({
      messages: [
        {
          role: 'system', content: questionSystemMessage
        },
        { role: 'user', content: userMessage },
      ],
      model: 'gpt-3.5-turbo-0125',
      response_format: { type: 'json_object' },
      temperature: 0.2,
    });

    const unparsed = questionCompletion.choices[0].message.content
    const questions = JSON.parse(questionCompletion.choices[0].message.content);


    const answerSystemMessage = 'You are a highly knowledgeable tutor, trained in every aspect of human endeavor from art to zoology. Your current task is to generate answers (output in json, as an array) to the previously generated questions (only give me letter options for multiple choice and t/f questions) with each answer labelled in accordance with the question number. The answers should be in the following format: { question_number: 1, answer: "Answer text (or just the correct option for multiple choice questions)" }';

    const answerCompletion = await openai.chat.completions.create({
          messages: [
              {
                  role: 'system',
                  content: answerSystemMessage,
              },
              { role: 'user', content: JSON.stringify(formattedQuestions) },
          ],
          model: 'gpt-3.5-turbo-1106',
          response_format: { type: 'json_object' },
      });

      let answers = JSON.parse(answerCompletion.choices[0].message.content);
      answers = { test: { answers: answers } };

      res.send({ questions, answers, formattedQuestions, unparsed });
  } catch (error) {
    console.error('Error fetching assistant response:', error);
    res.status(500).send(`Internal Server Error: ${error}`);
  }
});

app.listen(port, () => {
  console.log(`Server is running at http://localhost:${port}`);
});
