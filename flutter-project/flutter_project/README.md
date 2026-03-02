# Pathfinder – Navigational Assistance App

Pathfinder is a Flutter app built for the TSA competition to help blind and visually impaired users navigate their surroundings. It listens to voice input, captures a camera frame, and sends both to a local backend that uses a Qwen 3.5 vision‑language model (via the Hugging Face router) to describe the scene and provide contextual guidance.

## Prerequisites

- Flutter SDK installed
- A device or emulator with microphone and camera access
- Node.js (for the backend)
- Hugging Face access token (for the model)

## Running the Flutter app

From the `flutter_project` directory:

```bash
flutter pub get
flutter run
```

The main screen:
- Lets you start/stop listening with the floating microphone button
- Shows the recognized speech text
- Shows a preview of the most recent camera frame
- Displays the model’s response in a card at the bottom

## Running the backend

From `flutter_project/backend`:

```bash
cp .env.example .env   # or copy manually on Windows
# Edit .env and set HF_TOKEN (and optionally HF_MODEL / HF_API_URL)
npm install
npm start
```

The backend listens on `http://localhost:8080` and exposes:

- `POST /api/openai-proxy` – accepts `{ text, image_base64 }` and forwards to Qwen 3.5 via Hugging Face.

On Android emulators, point the Flutter app to `http://10.0.2.2:8080/api/openai-proxy` instead of `localhost` if you change the URL.

## Notes

- `backend/node_modules` and `backend/.env` are ignored by Git (see `.gitignore`).
- The response parsing is handled in `lib/services/backend_client.dart`.
- The AI response card UI lives in `lib/widgets/ai_response_card.dart`.
