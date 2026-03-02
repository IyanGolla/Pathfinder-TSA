const express = require('express');
const cors = require('cors');
require('dotenv').config();
const OpenAI = require('openai');

const app = express();
app.use(cors());
app.use(express.json({ limit: '20mb' }));

// Hugging Face router using OpenAI-compatible SDK
const HF_API_URL = process.env.HF_API_URL || 'https://router.huggingface.co/v1';
const HF_API_KEY = process.env.HF_TOKEN;
const HF_MODEL = process.env.HF_MODEL || 'Qwen/Qwen3-VL-8B-Instruct:fastest';

const openai = new OpenAI({
  apiKey: HF_API_KEY,
  baseURL: HF_API_URL,
});

// Simple proxy endpoint: accepts text + optional image and forwards to Qwen
app.post('/api/openai-proxy', async (req, res) => {
  if (!HF_API_KEY) {
    return res.status(500).json({ error: 'Server not configured. Set HF_TOKEN in environment.' });
  }

  const { text, image_base64 } = req.body || {};

  // Build chat message content: user text plus optional inline image
  const contentArray = [{ type: 'text', text: text || '' }];
  if (image_base64) {
    const dataUri = `data:image/jpeg;base64,${image_base64}`;
    contentArray.push({
      type: 'image_url',
      image_url: { url: dataUri },
    });
  }

  try {
    const response = await openai.chat.completions.create({
      model: HF_MODEL,
      messages: [
        {
          role: 'system',
          content:
            'You are Pathfinder, an assistive navigation assistant for a blind user. ' +
            'The user has spoken a voice command and shared a camera image of their surroundings. ' +
            'Give short, clear, spoken-friendly guidance that helps them understand the scene and move safely.',
        },
        {
          role: 'user',
          content: contentArray,
        },
      ],
    });

    return res.status(200).json(response);
  } catch (err) {
    // Surface APIError details if present, otherwise fall back to a generic message
    if (err instanceof OpenAI.APIError) {
      return res.status(err.status || 500).json(err.error || { error: err.message });
    }
    return res.status(500).json({ error: err.message || 'Unknown error' });
  }
});

// Streaming variant: streams the generated text back as it arrives.
app.post('/api/openai-proxy-stream', async (req, res) => {
  if (!HF_API_KEY) {
    return res.status(500).json({ error: 'Server not configured. Set HF_TOKEN in environment.' });
  }

  const { text, image_base64 } = req.body || {};

  const contentArray = [{ type: 'text', text: text || '' }];
  if (image_base64) {
    const dataUri = `data:image/jpeg;base64,${image_base64}`;
    contentArray.push({
      type: 'image_url',
      image_url: { url: dataUri },
    });
  }

  try {
    const stream = await openai.chat.completions.create({
      model: HF_MODEL,
      stream: true,
      messages: [
        {
          role: 'system',
          content:
            'You are Pathfinder, an assistive navigation assistant for a blind user. ' +
            'The user has spoken a voice command and shared a camera image of their surroundings. ' +
            'Give short, clear, spoken-friendly guidance that helps them understand the scene and move safely.',
        },
        {
          role: 'user',
          content: contentArray,
        },
      ],
    });

    res.setHeader('Content-Type', 'text/plain; charset=utf-8');

    for await (const chunk of stream) {
      const delta = chunk.choices?.[0]?.delta?.content || '';
      if (delta) {
        res.write(delta);
      }
    }

    res.end();
  } catch (err) {
    if (err instanceof OpenAI.APIError) {
      return res.status(err.status || 500).json(err.error || { error: err.message });
    }
    return res.status(500).json({ error: err.message || 'Unknown error' });
  }
});

const PORT = process.env.PORT || 8080;
app.listen(PORT, () => console.log(`HF Qwen proxy listening on port ${PORT}`));
