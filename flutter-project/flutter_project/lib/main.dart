import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'services/backend_client.dart';
import 'widgets/ai_response_card.dart';
import 'widgets/object_detection_screen.dart';
import 'services/object_detector_service.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

import 'dart:io';
import "package:flutter/foundation.dart";

void main() {
  runApp(const MyApp());
}

class _MainObjectBoundingBoxPainter extends CustomPainter {
  final List<DetectedObject> objects;
  final Size imageSize;

  _MainObjectBoundingBoxPainter({
    required this.objects,
    required this.imageSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint =
        Paint()
          ..color = Colors.greenAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5;

    final labelBgPaint = Paint()..color = Colors.black54;

    const labelStyle = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );

    for (final obj in objects) {
      final scaleX = size.width / imageSize.width;
      final scaleY = size.height / imageSize.height;

      final rect = Rect.fromLTRB(
        obj.boundingBox.left * scaleX,
        obj.boundingBox.top * scaleY,
        obj.boundingBox.right * scaleX,
        obj.boundingBox.bottom * scaleY,
      );

      canvas.drawRect(rect, boxPaint);

      String labelText = 'Object';
      if (obj.labels.isNotEmpty) {
        final best = obj.labels.reduce(
          (a, b) => a.confidence >= b.confidence ? a : b,
        );
        labelText =
            '${best.text} ${(best.confidence * 100).toStringAsFixed(0)}%';
      }

      final tp = TextPainter(
        text: TextSpan(text: labelText, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();

      final chipRect = Rect.fromLTWH(
        rect.left,
        rect.top - tp.height - 4,
        tp.width + 8,
        tp.height + 4,
      );
      canvas.drawRect(chipRect, labelBgPaint);
      tp.paint(canvas, Offset(chipRect.left + 4, chipRect.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant _MainObjectBoundingBoxPainter oldDelegate) {
    return oldDelegate.objects != objects || oldDelegate.imageSize != imageSize;
  }
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
  // Object detection
  final _objectDetectorService = ObjectDetectorService();
  List<DetectedObject> _detectedObjects = [];
  Size _detectionImageSize = Size.zero;
  bool _detectionBusy = false;

  // Backend communication variables
  String _serverUrl = 'http://192.169.215.209:8080';
  String? _lastAiResponse;
  bool _isSending = false;
  String? _lastError;

  // Text-to-speech variables
  final FlutterTts _tts = FlutterTts();
  // TODO: Make these user-customizable via voice commands
  double _ttsRate = 1.0;
  double _ttsPitch = 1.0;
  double _ttsVolume = 1.0;
  String _ttsLanguage = 'en-GB';

  // UI variables
  late TextEditingController _serverUrlController;

  // Wake-word / hands-free speech state.
  bool _wakeListeningEnabled = false;
  bool _awaitingWakeWord = false;
  bool _capturingCommand = false;
  bool _commandProcessing = false; // Prevent duplicate captures
  bool _isStartingListening = false; // Prevent concurrent startup attempts
  String _currentCommandBuffer = '';

  @override
  void initState() {
    super.initState();
    _serverUrlController = TextEditingController();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Load settings first, then initialize
    await _loadServerUrl();
    await _loadTtsSettings();
    _initTts();
    // Prepare speech recognition and camera
    _initSpeech();
    _initCamera();
  }

  Future<void> _loadServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _serverUrl = prefs.getString('serverUrl') ?? 'http://localhost:8080';
      _serverUrlController.text = _serverUrl;
    });
  }

  Future<void> _saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('serverUrl', url);
    setState(() {
      _serverUrl = url;
      _serverUrlController.text = url;
    });
  }

  Future<void> _loadTtsSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ttsRate = prefs.getDouble('ttsRate') ?? 1.0;
      _ttsPitch = prefs.getDouble('ttsPitch') ?? 1.0;
      _ttsVolume = prefs.getDouble('ttsVolume') ?? 1.0;
      _ttsLanguage = prefs.getString('ttsLanguage') ?? 'en-GB';
    });
  }

  Future<void> _saveTtsSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('ttsRate', _ttsRate);
    await prefs.setDouble('ttsPitch', _ttsPitch);
    await prefs.setDouble('ttsVolume', _ttsVolume);
    await prefs.setString('ttsLanguage', _ttsLanguage);

    // Update TTS immediately
    await _tts.setLanguage(_ttsLanguage);
    await _tts.setSpeechRate(_ttsRate);
    await _tts.setPitch(_ttsPitch);
    await _tts.setVolume(_ttsVolume);
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
          imageFormatGroup:
              Platform.isAndroid
                  ? ImageFormatGroup.nv21
                  : ImageFormatGroup.bgra8888,
        );
        await _cameraController!.initialize();
        // Initialize object detector and start image stream for live detection
        _objectDetectorService.initialize();
        try {
          await _cameraController!.startImageStream(_processCameraImage);
        } catch (e) {
          // Some devices or camera plugin versions may not support simultaneous
          // image stream + picture capture. If starting the stream fails,
          // continue without the live detection stream.
          print('Warning: could not start image stream: $e');
        }
        _cameraInitialized = true;
        setState(() {});
      }
    } catch (e) {
      // If the camera fails, keep the app running in audio-only mode.
    }
  }

  void _processCameraImage(CameraImage image) async {
    if (_detectionBusy) return;
    _detectionBusy = true;

    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      _detectionBusy = false;
      return;
    }

    final inputImage = _objectDetectorService.inputImageFromCameraImage(
      image,
      controller.description,
      controller.value.deviceOrientation,
    );

    if (inputImage == null) {
      _detectionBusy = false;
      return;
    }

    try {
      final objects = await _objectDetectorService.processImage(inputImage);
      if (mounted) {
        setState(() {
          _detectedObjects = objects;
          _detectionImageSize = Size(
            image.width.toDouble(),
            image.height.toDouble(),
          );
        });
      }
    } catch (e) {
      // ignore detection errors
    } finally {
      _detectionBusy = false;
    }
  }

  void _startListening() async {
    // Ensure speech listening hasn't already started and we're not already trying to start
    if (!_speechEnabled) return;
    if (_speechToText.isListening || _isStartingListening) {
      print("Already listening or starting, skipping");
      return;
    }

    _isStartingListening = true; // Set flag to prevent concurrent attempts

    try {
      // When listening starts, it should be awaiting wake work and not capturing a command
      _awaitingWakeWord = true;
      _capturingCommand = false;
      _currentCommandBuffer = '';

      print("Starting speech recognition...");

      // New way to set listening options (old way was deprecated)
      SpeechListenOptions speechListenOptions = SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
      );

      await _speechToText.listen(
        onResult: _onSpeechResult,
        listenFor: const Duration(hours: 1),
        pauseFor: const Duration(seconds: 5),
        listenOptions: speechListenOptions,
      );
    } catch (e) {
      // Suppress the "already started" error - it's harmless and can occur due to race conditions
      if (!e.toString().contains('already started')) {
        print("Error starting speech recognition: $e");
      }
    } finally {
      _isStartingListening = false; // Clear flag
      setState(() {});
    }
  }

  void _stopListening() async {
    _wakeListeningEnabled = false;
    _awaitingWakeWord = false;
    _capturingCommand = false;
    _commandProcessing = false;
    _isStartingListening = false;
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
    print("Speech status: $status");
    final s = status.toLowerCase();

    // Ensure that the user is finished speaking.
    final ended =
        s.contains('notlistening') ||
        s.contains('not_listening') ||
        s.contains('not listening') ||
        s.contains('done');

    if (!ended) return;

    // If we were capturing a command, finalize it and trigger image capture.
    // Use _commandProcessing flag to prevent duplicate captures
    if (_capturingCommand && !_commandProcessing) {
      _commandProcessing = true; // Mark that we're processing this command
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
      _commandProcessing = false; // Mark as done processing
    }

    // If wake-mode is still enabled, go back to listening for the wake word.
    // Always attempt to restart if wake listening is enabled, with a small delay
    if (_wakeListeningEnabled) {
      _awaitingWakeWord = true;
      // Add a small delay to ensure the previous listen session is fully cleaned up
      await Future.delayed(const Duration(milliseconds: 300));
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
      // Start backend processing in background without awaiting it
      // This allows speech recognition to restart immediately
      _sendToBackend(_lastWords, bytes);
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

    final backendClient = BackendClient(baseUrl: _serverUrl);

    try {
      // Don't start speaking until previous response is finished speaking.
      await _tts.stop();

      // Call backendClient to send text and image and interpret response.
      // After each chunk is received, update the UI.
      await for (final chunk in backendClient.streamTextAndImage(
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
    try {
      _cameraController?.stopImageStream();
    } catch (_) {}
    _objectDetectorService.dispose();
    _cameraController?.dispose();
    _serverUrlController.dispose();
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
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CameraPreview(_cameraController!),
                      if (_detectedObjects.isNotEmpty &&
                          _detectionImageSize != Size.zero)
                        CustomPaint(
                          painter: _MainObjectBoundingBoxPainter(
                            objects: _detectedObjects,
                            imageSize: _detectionImageSize,
                          ),
                        ),
                      // small badge for count
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_detectedObjects.length} object(s)',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
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
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => SettingsScreen(parent: this),
                ),
              );
            },
            heroTag: 'settings',
            tooltip: 'Settings',
            child: Icon(Icons.settings),
          ),
          SizedBox(height: 16),
          FloatingActionButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const ObjectDetectionScreen(),
                ),
              );
            },
            heroTag: 'object_detection',
            tooltip: 'Object Detection',
            child: Icon(Icons.camera_enhance),
          ),
          SizedBox(height: 16),
          FloatingActionButton(
            onPressed: () {
              if (_wakeListeningEnabled) {
                _stopListening();
              } else {
                _wakeListeningEnabled = true;
                _startListening();
              }
            },
            heroTag: 'listening',
            tooltip:
                _wakeListeningEnabled
                    ? 'Stop Pathfinder listening'
                    : 'Start Pathfinder listening',
            child: Icon(
              _wakeListeningEnabled ? Icons.hearing : Icons.hearing_disabled,
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final _MyHomePageState parent;

  const SettingsScreen({required this.parent, super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _serverUrlController;
  late double _ttsRate;
  late double _ttsPitch;
  late double _ttsVolume;
  late String _ttsLanguage;

  @override
  void initState() {
    super.initState();
    _serverUrlController = TextEditingController(
      text: widget.parent._serverUrl,
    );
    _ttsRate = widget.parent._ttsRate;
    _ttsPitch = widget.parent._ttsPitch;
    _ttsVolume = widget.parent._ttsVolume;
    _ttsLanguage = widget.parent._ttsLanguage;
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    super.dispose();
  }

  void _saveSettings() {
    widget.parent._saveServerUrl(_serverUrlController.text);
    widget.parent._ttsRate = _ttsRate;
    widget.parent._ttsPitch = _ttsPitch;
    widget.parent._ttsVolume = _ttsVolume;
    widget.parent._ttsLanguage = _ttsLanguage;
    widget.parent._saveTtsSettings();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Server URL
            const Text(
              'Backend Server',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _serverUrlController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://localhost:8080',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),

            // Text-to-Speech Settings
            const Text(
              'Text-to-Speech',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            // Language Selection
            TextField(
              decoration: const InputDecoration(
                labelText: 'Language',
                hintText: 'en-GB',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  _ttsLanguage = value.isEmpty ? 'en-GB' : value;
                });
              },
              controller: TextEditingController(text: _ttsLanguage),
            ),
            const SizedBox(height: 16),

            // Speech Rate
            Text('Speech Rate: ${_ttsRate.toStringAsFixed(2)}'),
            Slider(
              value: _ttsRate,
              min: 0.5,
              max: 2.0,
              divisions: 30,
              label: _ttsRate.toStringAsFixed(2),
              onChanged: (value) {
                setState(() {
                  _ttsRate = value;
                });
              },
            ),
            const SizedBox(height: 16),

            // Pitch
            Text('Pitch: ${_ttsPitch.toStringAsFixed(2)}'),
            Slider(
              value: _ttsPitch,
              min: 0.5,
              max: 2.0,
              divisions: 30,
              label: _ttsPitch.toStringAsFixed(2),
              onChanged: (value) {
                setState(() {
                  _ttsPitch = value;
                });
              },
            ),
            const SizedBox(height: 16),

            // Volume
            Text('Volume: ${_ttsVolume.toStringAsFixed(2)}'),
            Slider(
              value: _ttsVolume,
              min: 0.0,
              max: 1.0,
              divisions: 20,
              label: _ttsVolume.toStringAsFixed(2),
              onChanged: (value) {
                setState(() {
                  _ttsVolume = value;
                });
              },
            ),
            const SizedBox(height: 24),

            // Save Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saveSettings,
                child: const Text('Save Settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
