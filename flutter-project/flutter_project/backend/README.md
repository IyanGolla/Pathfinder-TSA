# Backend -- Hugging Face Qwen VL Proxy

A small Express server that sits between the Flutter app and the Hugging Face Inference Router. It keeps your HF token on the server side, manages per-session conversation history, and supports both regular and streaming responses.

## Setup

1. Copy `.env.example` to `.env` and fill in your values:

   ```bash
   cp .env.example .env   # on Windows: copy .env.example .env
   ```

2. Edit `.env`:
   - **`HF_TOKEN`** (required) -- your Hugging Face access token
   - `HF_API_URL` (optional) -- defaults to `https://router.huggingface.co/v1`
   - `HF_MODEL` (optional) -- defaults to `Qwen/Qwen3-VL-8B-Instruct:fastest`
   - `PORT` (optional) -- defaults to `8080`

3. Install and run:

   ```bash
   npm install
   npm start
   ```

The server will print `HF Qwen proxy listening on port 8080` when it's ready.

## Endpoints

### POST `/api/openai-proxy`

Standard request/response. Sends the user's text and camera image to the model and returns the full reply as JSON.

**Request body:**

```json
{
  "text": "what's in front of me?",
  "image_base64": "<base64-encoded JPEG>",
  "sessionId": "optional-session-id"
}
```

**Response:**

```json
{
  "sessionId": "auto-generated-or-echoed-id",
  "reply": "I can see a hallway with a door on your left...",
  "raw": { ... }
}
```

If you omit `sessionId`, the server generates one and returns it. Pass it back on subsequent requests to maintain conversation context.

### POST `/api/openai-proxy-stream`

Same request format, but the response is streamed as `text/plain` -- each chunk of generated text is written as it arrives. The Flutter app uses this endpoint by default so the user hears the response sooner.

### GET `/history/:sessionId`

Returns the conversation history for a given session.

### POST `/clear/:sessionId`

Clears the conversation history for a given session.

## Conversation Memory

The server keeps up to 200 messages per session in memory. When calling the model, it includes the most recent 8 exchanges (16 messages) as context. History is lost when the server restarts.

## Notes

- `node_modules/` and `.env` are git-ignored.
- The server uses the OpenAI SDK pointed at Hugging Face's OpenAI-compatible router, so switching to a different provider is straightforward -- just change the URL and token.
- On Android emulators, the Flutter app should point to `http://10.0.2.2:8080` instead of `localhost`.
