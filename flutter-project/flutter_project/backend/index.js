const express = require('express');
const cors = require('cors');
require('dotenv').config();
const OpenAI = require('openai');

const app = express();
app.use(cors());
app.use(express.json({ limit: '20mb' }));

// --- Conversation memory (in-memory, lost on restart) ---
const histories = new Map();
const HISTORY_LIMIT = 200;
// How many previous exchanges (user+assistant turns) to send to the model
const HISTORY_TURNS = 8;

function ensureHistory(sessionId) {
  if (!histories.has(sessionId)) histories.set(sessionId, []);
  return histories.get(sessionId);
}

function addToHistory(sessionId, role, text) {
  const h = ensureHistory(sessionId);
  h.push({ role, text, ts: Date.now() });
  if (h.length > HISTORY_LIMIT) h.splice(0, h.length - HISTORY_LIMIT);
}

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

  const { text, image_base64, sessionId: maybeId } = req.body || {};
  const sessionId = maybeId || `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;

  // Build chat message content: user text plus optional inline image
  const contentArray = [{ type: 'text', text: text || '' }];
  if (image_base64) {
    const dataUri = `data:image/jpeg;base64,${image_base64}`;
    contentArray.push({
      type: 'image_url',
      image_url: { url: dataUri },
    });
  }

  // Save user message to history
  try {
    addToHistory(sessionId, 'user', contentArray);

    // Build messages: system -> previous history -> current user
    const systemMsg = {
      role: 'system',
      content:
        'You are Pathfinder, an assistive navigation assistant for a blind user. ' +
        'The user has spoken a voice command and shared a camera image of their surroundings. ' +
        'Give short, clear, spoken-friendly guidance that helps them understand the scene and move safely.',
    };

    const historyMessages = ensureHistory(sessionId)
      .slice(-HISTORY_TURNS * 2)
      .map((h) => ({ role: h.role, content: h.text }));
    const messages = [systemMsg, ...historyMessages, { role: 'user', content: contentArray }];

    const response = await openai.chat.completions.create({
      model: HF_MODEL,
      messages,
    });

    // Extract a textual reply from the provider response
    function extractText(content) {
      if (!content) return '';
      if (typeof content === 'string') return content;
      if (Array.isArray(content)) return content.map((c) => (typeof c === 'string' ? c : c.text || JSON.stringify(c))).join(' ');
      if (typeof content === 'object') return content.text || JSON.stringify(content);
      return String(content);
    }

    const choice = response?.choices?.[0];
    let replyRaw = choice?.message?.content ?? choice?.delta?.content ?? '';
    const reply = extractText(replyRaw);

    addToHistory(sessionId, 'assistant', reply);

    return res.status(200).json({ sessionId, reply, raw: response });
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

  const { text, image_base64, sessionId: maybeId } = req.body || {};
  const sessionId = maybeId || `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;

  const contentArray = [{ type: 'text', text: text || '' }];
  if (image_base64) {
    const dataUri = `data:image/jpeg;base64,${image_base64}`;
    contentArray.push({
      type: 'image_url',
      image_url: { url: dataUri },
    });
  }

  try {
    // record user message
    addToHistory(sessionId, 'user', contentArray);

    const systemMsg = {
      role: 'system',
      content:
        'You are Pathfinder, an assistive navigation assistant for a blind user. ' +
        'The user has spoken a voice command and shared a camera image of their surroundings. ' +
        'Give short, clear, spoken-friendly guidance that helps them understand the scene and move safely.',
    };

    const historyMessages = ensureHistory(sessionId)
      .slice(-HISTORY_TURNS * 2)
      .map((h) => ({ role: h.role, content: h.text }));
    const messages = [systemMsg, ...historyMessages, { role: 'user', content: contentArray }];

    const stream = await openai.chat.completions.create({
      model: HF_MODEL,
      stream: true,
      messages,
    });

    res.setHeader('Content-Type', 'text/plain; charset=utf-8');

    let acc = '';
    for await (const chunk of stream) {
      const delta = chunk.choices?.[0]?.delta?.content || '';
      if (delta) {
        res.write(delta);
        acc += typeof delta === 'string' ? delta : JSON.stringify(delta);
      }
    }

    // save accumulated assistant reply to history
    addToHistory(sessionId, 'assistant', acc);

    res.end();
  } catch (err) {
    // Avoid double-sending errors if stream already started
    if (res.headersSent) { return; } 

    // Return APIError details if present, otherwise fall back to a generic message
    if (err instanceof OpenAI.APIError) {
      return res.status(err.status || 500).json(err.error || { error: err.message });
    }
    return res.status(500).json({ error: err.message || 'Unknown error' });
  }
});

const PORT = process.env.PORT || 8080;
// History endpoints
app.get('/history/:sessionId', (req, res) => {
  const sessionId = req.params.sessionId;
  const history = histories.get(sessionId) || [];
  res.json({ sessionId, history });
});

app.post('/clear/:sessionId', (req, res) => {
  const sessionId = req.params.sessionId;
  histories.delete(sessionId);
  res.json({ sessionId, cleared: true });
});

app.listen(PORT, () => console.log(`HF Qwen proxy listening on port ${PORT}`));
