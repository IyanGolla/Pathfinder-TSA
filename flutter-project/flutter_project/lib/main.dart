import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
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
  final SpeechToText _speechToText = SpeechToText();
  final BackendClient _backendClient = const BackendClient();
  bool _speechEnabled = false;
  String _lastWords = '';
  CameraController? _cameraController;
  CameraDescription? _cameraDescription;
  bool _cameraInitialized = false;
  final List<Uint8List> _capturedImages = [];
  String? _lastAiResponse;
  bool _isSending = false;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    // Prepare speech recognition and camera once the widget is ready.
    _initSpeech();
    _initCamera();
  }

  void _initSpeech() async {
    _speechEnabled = await _speechToText.initialize();
    setState(() {});
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
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
    await _speechToText.listen(onResult: _onSpeechResult);
    setState(() {});
  }

  void _stopListening() async {
    await _speechToText.stop();
    setState(() {});
    await _captureFrame();
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() {
      _lastWords = result.recognizedWords;
    });
  }

  Future<void> _captureFrame() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    try {
      final XFile picture = await _cameraController!.takePicture();
      final bytes = await picture.readAsBytes();
      _capturedImages.insert(0, bytes);
      setState(() {});
      // Send the spoken text and latest frame to the backend for analysis.
      await _sendToBackend(_lastWords, bytes);
    } catch (e) {
      // If capture fails, skip this round and keep going.
    }
  }

  Future<void> _sendToBackend(String text, Uint8List imageBytes) async {
    _lastError = null;
    _isSending = true;
    setState(() {});
    try {
      final result = await _backendClient.sendTextAndImage(
        text: text,
        imageBytes: imageBytes,
      );
      _lastAiResponse = result;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                            ? 'Tap the microphone to start listening...'
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
                  onClear: () {
                    setState(() {
                      _lastAiResponse = null;
                      _lastError = null;
                    });
                  },
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed:
            _speechToText.isNotListening ? _startListening : _stopListening,
        tooltip: 'Listen',
        child: Icon(_speechToText.isNotListening ? Icons.mic_off : Icons.mic),
      ),
    );
  }
}
