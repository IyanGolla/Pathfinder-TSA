# Backend: Hugging Face Qwen Proxy

Simple Express proxy that keeps your Hugging Face token on the server and forwards requests from the Flutter app to the Hugging Face Inference Router using an OpenAI‑compatible client.

## Setup

1. Copy `.env.example` to `.env` and set:
   - `HF_TOKEN` – your Hugging Face access token
   - (optional) `HF_API_URL` – defaults to `https://router.huggingface.co/v1`
   - (optional) `HF_MODEL` – defaults to `Qwen/Qwen3.5-397B-A17B:fastest`
2. Install dependencies and start the server:

```bash
cd flutter-project/flutter_project/backend
npm install
npm start
```

3. By default the app calls `http://localhost:8080/api/openai-proxy`. On Android emulators use `http://10.0.2.2:8080/api/openai-proxy`.

## Request format (POST /api/openai-proxy)

```json
{
  "text": "recognized speech text",
  "image_base64": "...base64 image bytes..."
}
```

The proxy converts this into a Chat Completions payload and forwards it to the configured Qwen model via the Hugging Face router, then returns the raw OpenAI‑compatible response back to the Flutter app.
