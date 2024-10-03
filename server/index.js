import express from 'express';
import bodyParser from 'body-parser';
import axios from 'axios';

const app = express();
const port = 8080;

const apiKey = '';

app.use(bodyParser.json({ limit: '50mb' }));

app.post('/', async (req, res) => {
    try {
        const { prompt, images } = req.body;

        const response = await axios.post('https://api.openai.com/v1/chat/completions', {
            model: 'gpt-4o',
            messages: [
                { role: 'user', content: [
                    { type: 'text', text: prompt },
                    ...images.map(img => ({
                        type: 'image_url',
                        image_url: { url: `data:image/jpeg;base64,${img}` } 
                    }))
                ]}
            ],
            max_tokens: 600
        }, {
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${apiKey}`
            }
        });

        if (response.status === 200) {
            res.json({ result: response.data.choices[0].message.content }); 
        } else {
            res.status(response.status).json({ error: 'OpenAI API error' });
        }
    } catch (error) {
        console.error('Error:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

app.listen(port, () => {
    console.log(`Server listening at http://localhost:${port}`); 
});