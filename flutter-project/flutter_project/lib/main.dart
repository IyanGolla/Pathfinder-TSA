import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'services/backend_client.dart';
import 'widgets/ai_response_card.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'Flutter Demo', home: MyHomePage());
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  // Speech recognition variables
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  String _lastWords = '';

  // Camera feed variables
  CameraController? _cameraController;
  CameraDescription? _cameraDescription;
  bool _cameraInitialized = false;
  final List<Uint8List> _capturedImages = [];

  // Backend communication variables
  final BackendClient _backendClient = BackendClient();
  String? _lastAiResponse;
  bool _isSending = false;
  String? _lastError;

  // Text-to-speech variables
  final FlutterTts _tts = FlutterTts();
  // TODO: Make these user-customizable via voice commands
  double _ttsRate = 1.3;
  double _ttsPitch = 1.2;
  double _ttsVolume = 1.0;
  String _ttsLanguage = 'en-GB';

  // Wake-word / hands-free speech state. Initially set to true to start listening immediately.
  bool _wakeListeningEnabled = true;
  bool _awaitingWakeWord = true;
  bool _capturingCommand = false;
  String _currentCommandBuffer = '';

  @override
  void initState() {
    super.initState();
    // Prepare speech recognition, text-to-speech, and camera once the widget is ready.
    _initSpeech();
    _initTts();
    _initCamera();
  }

  void _initSpeech() async {
    // Initialize speech recognition listener and begin listening.
    _speechEnabled = await _speechToText.initialize();
    _speechToText.statusListener = _onSpeechStatus;
    setState(() {});
    _startListening();
  }

  void _initTts() {
    // Set initial text-to-speech voice settings
    _tts.setLanguage(_ttsLanguage);
    _tts.setSpeechRate(_ttsRate);
    _tts.setPitch(_ttsPitch);
    _tts.setVolume(_ttsVolume);
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        // Use the first camera found
        // TODO: Make camera selection logic more robust (flip camera option?)
        _cameraDescription = cameras.first;
        _cameraController = CameraController(
          _cameraDescription!,
          ResolutionPreset.medium,
          enableAudio: false,
        );
        await _cameraController!.initialize();
        _cameraInitialized = true;
        setState(() {});
      }
    } catch (e) {
      // If the camera fails, keep the app running in audio-only mode.
    }
  }

  void _startListening() async {
    // Ensure speech listening hasn't already started
    if (!_speechEnabled) return;
    if (_speechToText.isListening) return;

    // When listening starts, it should be awaiting wake work and not capturing a command
    _awaitingWakeWord = true;
    _capturingCommand = false;
    _currentCommandBuffer = '';

    // New way to set listening options (old way was deprecated)
    SpeechListenOptions speechListenOptions = SpeechListenOptions(
      partialResults: true,
      cancelOnError: true,
    );

    await _speechToText.listen(
      onResult: _onSpeechResult,
      listenFor: const Duration(minutes: 10),
      pauseFor: const Duration(seconds: 3),
      listenOptions: speechListenOptions,
    );

    setState(() {});
  }

  void _stopListening() async {
    _wakeListeningEnabled = false;
    _awaitingWakeWord = false;
    _capturingCommand = false;
    _currentCommandBuffer = '';
    await _speechToText.stop();
    setState(() {});
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    final recognized = result.recognizedWords;

    // Update UI to show recognized words
    setState(() {
      _lastWords = recognized;
    });

    final lower = recognized.toLowerCase();

    if (_awaitingWakeWord) {
      // Detect the wake work "Pathfinder" that signifies the start of a voice command.
      if (lower.contains('pathfinder')) {
        // Ensure nothing interrupts the voice command and it doesn't restart every time new words are recognized
        _awaitingWakeWord = false;
        _capturingCommand = true;

        // Use any words after the wake word as the start of the command.
        final index = lower.indexOf('pathfinder');
        String after = '';
        if (index >= 0) {
          after = recognized.substring(index + 'pathfinder'.length).trim();
        }
        _currentCommandBuffer = after;
      }
      // Detect variants of the wake word such as "path finder", making it more forgiving when speaking commands.
      // Same code as above but with "path finder" instead of "pathfinder"
      else if (lower.contains('path finder')) {
        _awaitingWakeWord = false;
        _capturingCommand = true;

        final index = lower.indexOf('path finder');
        String after = '';
        if (index >= 0) {
          after = recognized.substring(index + 'path finder'.length).trim();
        }
        _currentCommandBuffer = after;
      }
      return;
    }

    if (_capturingCommand) {
      // Keep the latest best guess for the full command.
      _currentCommandBuffer = recognized;
    }
  }

  void _onSpeechStatus(String status) async {
    final s = status.toLowerCase();

    // Ensure that the user is finished speaking.
    final ended =
        s.contains('notlistening') ||
        s.contains('not_listening') ||
        s.contains('not listening') ||
        s.contains('done');

    if (!ended) return;

    // If we were capturing a command, finalize it and trigger image capture.
    if (_capturingCommand) {
      String command = _currentCommandBuffer.trim();
      if (command.isEmpty) {
        command = _lastWords.trim();
      }

      if (command.isNotEmpty) {
        // Strip any leading wake word if it slipped into the buffer.
        final lower = command.toLowerCase();
        if (lower.startsWith('pathfinder')) {
          command = command.substring('pathfinder'.length).trimLeft();
        }

        _lastWords = command;
        await _captureFrame();
      }

      _capturingCommand = false;
      _currentCommandBuffer = '';
    }

    // If wake-mode is still enabled, go back to listening for the wake word.
    if (_wakeListeningEnabled && !_speechToText.isListening) {
      _awaitingWakeWord = true;
      _startListening();
    } else {
      _awaitingWakeWord = false;
    }

    setState(() {});
  }

  Future<void> _captureFrame() async {
    // Ensure camera controller exists
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    try {
      // TODO: Find optimal image resolution for speed and accuracy.
      final XFile picture = await _cameraController!.takePicture();
      final bytes = await picture.readAsBytes();
      // Insert into front of captured images list
      _capturedImages.insert(0, bytes);
      setState(() {});
      await _sendToBackend(_lastWords, bytes);
    } catch (e) {
      // If capture fails, skip this round and keep going.
    }
  }

  Future<void> _sendToBackend(String text, Uint8List imageBytes) async {
    // Set sending state to true and reset AI response view
    _lastError = null;
    _isSending = true;
    _lastAiResponse = '';
    setState(() {});

    try {
      // Don't start speaking until previous response is finished speaking.
      await _tts.stop();

      // Call backendClient to send text and image and interpret response.
      // After each chunk is received, update the UI.
      await for (final chunk in _backendClient.streamTextAndImage(
        text: text,
        imageBytes: imageBytes,
      )) {
        _lastAiResponse = '$_lastAiResponse$chunk';
        setState(() {});
      }
      // Speak AI response using text-to-speech
      if (_lastAiResponse != null && _lastAiResponse!.trim().isNotEmpty) {
        await _tts.speak(_lastAiResponse!.trim());
      }
    } catch (e) {
      _lastError = e.toString();
    } finally {
      _isSending = false;
      setState(() {});
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _tts.stop();
    super.dispose();
  }

  void _clearAi() {
    setState(() {
      _lastAiResponse = null;
      _lastError = null;
    });
    _tts.stop();
  }

  @override
  Widget build(BuildContext context) {
    // TODO: Rework entire UI
    return Scaffold(
      appBar: AppBar(title: Text('Speech Demo')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _cameraInitialized && _cameraController != null
                ? SizedBox(
                  height: 240,
                  child: CameraPreview(_cameraController!),
                )
                : SizedBox.shrink(),
            SizedBox(height: 8),
            Container(
              padding: EdgeInsets.all(16),
              child: Text(
                'Recognized words:',
                style: TextStyle(fontSize: 20.0),
              ),
            ),
            Expanded(
              child: Container(
                padding: EdgeInsets.all(16),
                child: SingleChildScrollView(
                  child: Text(
                    _speechToText.isListening
                        ? _lastWords
                        : (_speechEnabled
                            ? 'Say \"Pathfinder\" to wake the app.'
                            : 'Speech not available'),
                  ),
                ),
              ),
            ),
            if (_capturedImages.isNotEmpty) Divider(),
            if (_capturedImages.isNotEmpty)
              SizedBox(
                height: 140,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children:
                        _capturedImages.map((bytes) {
                          return Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.memory(bytes, height: 120),
                            ),
                          );
                        }).toList(),
                  ),
                ),
              ),
            if (_isSending) LinearProgressIndicator(),
            if (_lastError != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'Error: $_lastError',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            if (_lastAiResponse != null)
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: AiResponseCard(
                  response: _lastAiResponse!,
                  onClear: _clearAi,
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_wakeListeningEnabled) {
            _stopListening();
          } else {
            _wakeListeningEnabled = true;
            _startListening();
          }
        },
        tooltip:
            _wakeListeningEnabled
                ? 'Stop Pathfinder listening'
                : 'Start Pathfinder listening',
        child: Icon(
          _wakeListeningEnabled ? Icons.hearing : Icons.hearing_disabled,
        ),
      ),
    );
  }
}
