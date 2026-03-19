# Pathfinder -- Assistive Navigation App

Pathfinder is a Flutter app built for the TSA competition. It helps blind and visually impaired users understand and navigate their surroundings using real-time object detection, voice commands, and an AI vision-language model.

The user speaks a command (triggered by the wake word **"Pathfinder"**), the app grabs a camera frame, sends both to a backend running Qwen VL via Hugging Face, and reads the AI's response aloud -- all hands-free.

## App Architecture

<!-- Replace the placeholder below with your flowchart image, e.g.:
     ![App Architecture](assets/docs/flowchart.png)
-->
*[ Flowchart image goes here ]*

## Features

- **Wake-word activation** -- say "Pathfinder" to start a command, no button press needed
- **Real-time object detection** -- MobileNetV1 (SSD) via TFLite, running on a background isolate
- **Object alerts** -- nearby relevant objects (people, vehicles, furniture, etc.) are announced via TTS
- **AI scene description** -- camera frame + spoken command are sent to a Qwen VL model for contextual guidance
- **Streaming responses** -- the backend streams the model's reply so the user hears it faster
- **Conversation memory** -- the backend keeps session history so follow-up questions work naturally
- **Configurable TTS** -- rate, pitch, volume, and language are adjustable in settings
- **Settings persistence** -- server URL and TTS preferences are saved across sessions via SharedPreferences

## Project Structure

```
flutter_project/
├── lib/
│   ├── main.dart                      # App entry, HomePage, SettingsScreen
│   ├── models/
│   │   ├── recognition.dart           # Detection result model
│   │   └── screen_parameters.dart     # Screen size singleton
│   ├── services/
│   │   ├── backend_client.dart        # HTTP client for the AI backend
│   │   ├── detector_service.dart      # TFLite detection on background isolate
│   │   └── object_alert_service.dart  # Decides which detections to announce
│   ├── utils/
│   │   └── image_conversion.dart      # Camera format converters
│   └── widgets/
│       ├── ai_response_card.dart      # Card showing the AI response
│       ├── box_widget.dart            # Bounding box overlay
│       └── stats_widget.dart          # Detection timing stats row
├── assets/
│   ├── models/                        # TFLite model files
│   └── labels/                        # Label files for the model
├── backend/                           # Node.js proxy server (see backend/README.md)
└── test/
    └── widget_test.dart
```

## Prerequisites

- **Flutter SDK** (stable channel)
- A physical device or emulator with camera and microphone access
- **Node.js** 18+ (for the backend)
- A **Hugging Face** access token with Inference API access

## Getting Started

### 1. Start the backend

```bash
cd flutter_project/backend
cp .env.example .env        # on Windows: copy .env.example .env
# Edit .env and set HF_TOKEN to your Hugging Face token
npm install
npm start
```

The server starts on `http://localhost:8080` by default.

### 2. Run the Flutter app

```bash
cd flutter_project
flutter pub get
flutter run
```

On Android emulators, the backend URL needs to be `http://10.0.2.2:8080` instead of `localhost` (the emulator can't reach the host's localhost directly). You can change this in the app's Settings screen.

### 3. Use the app

1. Tap the ear icon to enable listening
2. Say **"Pathfinder"** followed by your question (e.g. "Pathfinder, what's in front of me?")
3. The app captures a camera frame, sends it with your command, and reads the response aloud
4. Detected objects are also announced automatically when they're close enough
5. Tap the eye icon to toggle object detection on or off

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/openai-proxy` | Send text + image, get a JSON response |
| POST | `/api/openai-proxy-stream` | Send text + image, get a streamed text response |
| GET | `/history/:sessionId` | Retrieve conversation history for a session |
| POST | `/clear/:sessionId` | Clear conversation history for a session |

See [backend/README.md](backend/README.md) for request/response details.

## Notes

- `backend/node_modules` and `backend/.env` are git-ignored.
- The default model is `Qwen/Qwen3-VL-8B-Instruct`. You can swap it by setting `HF_MODEL` in `.env`.
- Object detection runs entirely on-device -- the backend is only used for the AI vision + language queries.

## Next Steps

- **Voice-controlled settings** -- let the user change TTS speed, language, and server URL through voice commands instead of requiring the settings screen
- **On-device LLM** -- run the vision-language model locally on the phone so *all* features of the app work without an internet connection
- **Wearable hardware** (stretch goal) -- port Pathfinder to wearable devices like Meta smart glasses for a truly seamless experience
