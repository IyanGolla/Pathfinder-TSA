import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image/image.dart' as image_lib;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'models/recognition.dart';
import 'models/screen_parameters.dart';
import 'services/backend_client.dart';
import 'services/detector_service.dart';
import 'services/object_alert_service.dart';
import 'widgets/ai_response_card.dart';
import 'widgets/box_widget.dart';
import 'widgets/stats_widget.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const MyApp());
}

/// Root widget — sets up the MaterialApp and theme.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pathfinder',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const HomePage(),
    );
  }
}

/// Main screen: live camera preview with object detection, speech
/// recognition, wake-word command capture, and backend AI queries.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  // ── Speech recognition ──
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  String _lastWords = '';

  // ── Camera ──
  CameraController? _cameraController;
  bool _cameraInitialized = false;
  CameraImage? _latestFrame;

  // ── Object detection ──
  Detector? _detector;
  StreamSubscription? _detectorSubscription;
  List<Recognition>? _recognitions;
  Map<String, String>? _detectionStats;
  bool _detectionUpdateScheduled = false;
  DateTime _lastDetectorFrame = DateTime(0);
  bool _detectionEnabled = true;

  /// Set to false to hide the detection performance stats overlay.
  static const bool showDetectionStats = true;

  // ── Backend / AI ──
  String _serverUrl = 'http://localhost:8080';
  String? _lastAiResponse;
  bool _isSending = false;
  String? _lastError;

  // ── Text-to-speech ──
  final FlutterTts _tts = FlutterTts();
  double _ttsRate = 1.0;
  double _ttsPitch = 1.0;
  double _ttsVolume = 1.0;
  String _ttsLanguage = 'en-GB';

  // ── Object alerts ──
  final ObjectAlertService _objectAlerts = ObjectAlertService();
  bool _isSpeakingAlert = false;

  // ── Wake-word state machine ──
  // Flow: mic on → listen for "Pathfinder" → capture everything after
  // the wake word → speech ends → send command to backend → restart.
  bool _wakeListeningEnabled = false;
  bool _awaitingWakeWord = false;
  bool _capturingCommand = false;
  bool _commandProcessing = false;
  bool _isStartingListening = false;
  String _currentCommandBuffer = '';

  // ── Lifecycle ──

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _detector?.stop();
    _detectorSubscription?.cancel();
    _tts.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        _cameraController?.stopImageStream();
        _detector?.stop();
        _detectorSubscription?.cancel();
        _detector = null;
        _detectorSubscription = null;
        break;
      case AppLifecycleState.resumed:
        _initCamera();
        _initDetector();
        break;
      default:
    }
  }

  Future<void> _initializeApp() async {
    await _loadSettings();
    _applyTtsSettings();
    _initSpeech();
    await _initCamera();
    await _initDetector();
  }

  // ── Settings ──

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _serverUrl = prefs.getString('serverUrl') ?? 'http://localhost:8080';
      _ttsRate = prefs.getDouble('ttsRate') ?? 1.0;
      _ttsPitch = prefs.getDouble('ttsPitch') ?? 1.0;
      _ttsVolume = prefs.getDouble('ttsVolume') ?? 1.0;
      _ttsLanguage = prefs.getString('ttsLanguage') ?? 'en-GB';
    });
  }

  Future<void> _saveSettings({
    String? serverUrl,
    double? ttsRate,
    double? ttsPitch,
    double? ttsVolume,
    String? ttsLanguage,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (serverUrl != null) {
      _serverUrl = serverUrl;
      await prefs.setString('serverUrl', serverUrl);
    }
    if (ttsRate != null) {
      _ttsRate = ttsRate;
      await prefs.setDouble('ttsRate', ttsRate);
    }
    if (ttsPitch != null) {
      _ttsPitch = ttsPitch;
      await prefs.setDouble('ttsPitch', ttsPitch);
    }
    if (ttsVolume != null) {
      _ttsVolume = ttsVolume;
      await prefs.setDouble('ttsVolume', ttsVolume);
    }
    if (ttsLanguage != null) {
      _ttsLanguage = ttsLanguage;
      await prefs.setString('ttsLanguage', ttsLanguage);
    }
    _applyTtsSettings();
    setState(() {});
  }

  void _applyTtsSettings() {
    _tts.setLanguage(_ttsLanguage);
    _tts.setSpeechRate(_ttsRate);
    _tts.setPitch(_ttsPitch);
    _tts.setVolume(_ttsVolume);
  }

  // ── Camera & detection ──

  /// Opens the first available camera and starts the image stream.
  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      _cameraController?.dispose();
      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      await _cameraController!.startImageStream(_onCameraFrame);

      ScreenParameters.previewSize = _cameraController!.value.previewSize!;
      _cameraInitialized = true;
      setState(() {});
    } catch (e) {
      debugPrint('Camera init failed: $e');
    }
  }

  /// Starts the TFLite detector isolate and subscribes to results.
  Future<void> _initDetector() async {
    try {
      _detector = await Detector.start();
      _detectorSubscription = _detector!.resultsStream.stream.listen((values) {
        // Store latest results but throttle UI rebuilds to avoid
        // starving the main thread (and speech callbacks).
        _recognitions = values['recognitions'];
        _detectionStats = values['stats'];

        // Check for new objects to alert the user about
        if (_recognitions != null && _recognitions!.isNotEmpty) {
          _checkObjectAlerts(_recognitions!);
        }

        if (!_detectionUpdateScheduled) {
          _detectionUpdateScheduled = true;
          Future.delayed(const Duration(milliseconds: 200), () {
            _detectionUpdateScheduled = false;
            if (mounted) setState(() {});
          });
        }
      });
    } catch (e) {
      debugPrint('Detector init failed: $e');
    }
  }

  /// Callback for each camera frame — throttles to one detector call per 150 ms.
  void _onCameraFrame(CameraImage image) {
    _latestFrame = image;
    if (!_detectionEnabled) return;
    final now = DateTime.now();
    if (now.difference(_lastDetectorFrame).inMilliseconds >= 150) {
      _lastDetectorFrame = now;
      _detector?.processFrame(image);
    }
  }

  /// Encode the latest stream frame as JPEG for backend use.
  /// Runs conversion on a background isolate to keep the main thread free
  /// for speech recognition callbacks.
  Future<Uint8List?> _captureFrameFromStream() async {
    final frame = _latestFrame;
    if (frame == null) return null;

    // Serialize CameraImage plane data into transferrable types
    final planeData =
        frame.planes
            .map(
              (p) => {
                'bytes': Uint8List.fromList(p.bytes),
                'bytesPerRow': p.bytesPerRow,
                'bytesPerPixel': p.bytesPerPixel,
              },
            )
            .toList();

    return compute(_encodeFrameToJpeg, {
      'planes': planeData,
      'width': frame.width,
      'height': frame.height,
      'formatGroup': frame.format.group.name,
      'isAndroid': Platform.isAndroid,
    });
  }

  /// Top-level function for use with compute() — runs on a background isolate.
  static Uint8List? _encodeFrameToJpeg(Map<String, dynamic> data) {
    final planes = data['planes'] as List<Map<String, dynamic>>;
    final width = data['width'] as int;
    final height = data['height'] as int;
    final formatName = data['formatGroup'] as String;
    final isAndroid = data['isAndroid'] as bool;

    image_lib.Image? image;

    if (formatName == 'yuv420') {
      image = _decodeYuv420(planes, width, height);
    } else if (formatName == 'bgra8888') {
      final bytes = planes[0]['bytes'] as Uint8List;
      image = image_lib.Image.fromBytes(
        width: width,
        height: height,
        bytes: bytes.buffer,
        order: image_lib.ChannelOrder.rgba,
      );
    } else if (formatName == 'jpeg') {
      image = image_lib.decodeImage(planes[0]['bytes'] as Uint8List);
    } else if (formatName == 'nv21') {
      image = _decodeNv21(planes, width, height);
    }

    if (image == null) return null;
    if (isAndroid) image = image_lib.copyRotate(image, angle: 90);
    return Uint8List.fromList(image_lib.encodeJpg(image, quality: 85));
  }

  /// Decodes a YUV420 frame into an [image_lib.Image].
  static image_lib.Image _decodeYuv420(
    List<Map<String, dynamic>> planes,
    int width,
    int height,
  ) {
    final yPlane = planes[0]['bytes'] as Uint8List;
    final uPlane = planes[1]['bytes'] as Uint8List;
    final vPlane = planes[2]['bytes'] as Uint8List;
    final uvRowStride = planes[1]['bytesPerRow'] as int;
    final uvPixelStride = planes[1]['bytesPerPixel'] as int;
    final image = image_lib.Image(width: width, height: height);
    var uvIndex = 0;
    for (var y = 0; y < height; y++) {
      var pY = y * width;
      var pUV = uvIndex;
      for (var x = 0; x < width; x++) {
        final yVal = yPlane[pY];
        final uVal = uPlane[pUV];
        final vVal = vPlane[pUV];
        image.setPixelRgba(
          x,
          y,
          (yVal + 1.402 * (vVal - 128)).toInt(),
          (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128)).toInt(),
          (yVal + 1.772 * (uVal - 128)).toInt(),
          255,
        );
        pY++;
        if (x.isOdd) pUV += uvPixelStride;
      }
      if (y.isOdd) uvIndex += uvRowStride;
    }
    return image;
  }

  /// Decodes an NV21 frame into an [image_lib.Image].
  static image_lib.Image _decodeNv21(
    List<Map<String, dynamic>> planes,
    int width,
    int height,
  ) {
    final yuvBytes = planes[0]['bytes'] as Uint8List;
    final vuBytes = planes[1]['bytes'] as Uint8List;
    final image = image_lib.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final yIndex = y * width + x;
        final uvIndex = (y ~/ 2) * (width ~/ 2) + (x ~/ 2);
        final yVal = yuvBytes[yIndex];
        final vVal = vuBytes[uvIndex * 2];
        final uVal = vuBytes[uvIndex * 2 + 1];
        image.setPixelRgba(
          x,
          y,
          (yVal + 1.402 * (vVal - 128)).toInt(),
          (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128)).toInt(),
          (yVal + 1.772 * (uVal - 128)).toInt(),
          255,
        );
      }
    }
    return image;
  }

  // ── Speech recognition ──

  /// Initializes the speech-to-text engine and starts listening.
  void _initSpeech() async {
    _speechEnabled = await _speechToText.initialize();
    _speechToText.statusListener = _onSpeechStatus;
    setState(() {});
    // Auto-start listening (matches old working behavior)
    _startListening();
  }

  /// Begins a new speech recognition session in wake-word mode.
  void _startListening() async {
    if (!_speechEnabled || _speechToText.isListening || _isStartingListening) {
      return;
    }
    _isStartingListening = true;
    _awaitingWakeWord = true;
    _capturingCommand = false;
    _currentCommandBuffer = '';

    try {
      await _speechToText.listen(
        onResult: _onSpeechResult,
        listenFor: const Duration(hours: 1),
        pauseFor: const Duration(seconds: 5),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } catch (e) {
      if (!e.toString().contains('already started')) {
        debugPrint('Speech listen error: $e');
      }
    } finally {
      _isStartingListening = false;
      setState(() {});
    }
  }

  /// Stops speech recognition and resets all wake-word state.
  void _stopListening() {
    _wakeListeningEnabled = false;
    _awaitingWakeWord = false;
    _capturingCommand = false;
    _commandProcessing = false;
    _isStartingListening = false;
    _currentCommandBuffer = '';
    _speechToText.stop();
    setState(() {});
  }

  /// Called with partial and final speech results; detects the wake word
  /// and buffers everything spoken after it as the command.
  void _onSpeechResult(SpeechRecognitionResult result) {
    final recognized = result.recognizedWords;
    setState(() => _lastWords = recognized);

    final lower = recognized.toLowerCase();

    if (_awaitingWakeWord) {
      final afterIndex = _wakeWordEndIndex(lower);
      if (afterIndex != null) {
        _awaitingWakeWord = false;
        _capturingCommand = true;
        _currentCommandBuffer = recognized.substring(afterIndex).trim();
      }
      return;
    }

    if (_capturingCommand) {
      _currentCommandBuffer = recognized;
    }
  }

  /// Returns the string index just past the wake word, or null if not found.
  static int? _wakeWordEndIndex(String lower) {
    for (final wake in ['pathfinder', 'path finder']) {
      final i = lower.indexOf(wake);
      if (i >= 0) return i + wake.length;
    }
    return null;
  }

  /// Handles speech session lifecycle — finalizes the captured command
  /// when recognition stops and restarts listening if wake-mode is on.
  void _onSpeechStatus(String status) async {
    debugPrint("Speech status: $status");
    final s = status.toLowerCase();

    // Ensure that the user is finished speaking.
    final ended =
        s.contains('notlistening') ||
        s.contains('not_listening') ||
        s.contains('not listening') ||
        s.contains('done');

    if (!ended) return;

    // 150ms delay to allow any pending final onResult to arrive. On some
    // platforms the status event can come before the final result callback by a
    // few milliseconds; this makes sure the last word is captured.
    if (_capturingCommand)
      await Future.delayed(const Duration(milliseconds: 150));

    // If we were capturing a command, finalize it and trigger the image capture.
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
        await _processCommand(_lastWords);
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

  // ── Command processing & backend ──

  /// Captures the current camera frame and sends it with the command to the backend.
  Future<void> _processCommand(String command) async {
    final imageBytes = await _captureFrameFromStream();
    if (imageBytes == null) return;
    // Fire-and-forget so speech recognition can restart immediately.
    _sendToBackend(command, imageBytes);
  }

  /// Streams the AI response from the backend and speaks it via TTS.
  Future<void> _sendToBackend(String text, Uint8List imageBytes) async {
    _lastError = null;
    _isSending = true;
    _lastAiResponse = '';
    setState(() {});

    final client = BackendClient(baseUrl: _serverUrl);
    try {
      await _tts.stop();
      debugPrint('Sending command: $text');
      await for (final chunk in client.streamTextAndImage(
        text: text,
        imageBytes: imageBytes,
      )) {
        _lastAiResponse = '$_lastAiResponse$chunk';
        setState(() {});
      }
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

  void _clearAiResponse() {
    setState(() {
      _lastAiResponse = null;
      _lastError = null;
    });
    _tts.stop();
  }

  // ── Object alert TTS ──

  void _checkObjectAlerts(List<Recognition> recognitions) {
    final labels = _objectAlerts.getNewAlerts(recognitions);
    if (labels.isNotEmpty) {
      _speakObjectAlerts(labels);
    }
  }

  void _speakObjectAlerts(List<String> labels) async {
    // Don't interrupt an AI response or an ongoing alert
    if (_isSending || _isSpeakingAlert) return;

    _isSpeakingAlert = true;
    try {
      final message = labels.length == 1 ? labels.first : labels.join(', ');
      await _tts.speak(message);
    } finally {
      _isSpeakingAlert = false;
    }
  }

  // ── Main UI ──

  @override
  Widget build(BuildContext context) {
    ScreenParameters.screenSize = MediaQuery.sizeOf(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            _buildCameraPreview(),
            _buildBoundingBoxes(),
            _buildBottomOverlay(),
            if (_isSending)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
      floatingActionButton: _buildFabs(),
    );
  }

  Widget _buildCameraPreview() {
    if (!_cameraInitialized || _cameraController == null) {
      return const Center(
        child: Text(
          'Initializing camera...',
          style: TextStyle(color: Colors.white),
        ),
      );
    }
    return AspectRatio(
      aspectRatio: 1 / _cameraController!.value.aspectRatio,
      child: CameraPreview(_cameraController!),
    );
  }

  Widget _buildBoundingBoxes() {
    if (!_cameraInitialized ||
        _cameraController == null ||
        _recognitions == null ||
        _recognitions!.isEmpty) {
      return const SizedBox.shrink();
    }
    return AspectRatio(
      aspectRatio: 1 / _cameraController!.value.aspectRatio,
      child: Stack(
        children: _recognitions!.map((r) => BoxWidget(result: r)).toList(),
      ),
    );
  }

  Widget _buildBottomOverlay() {
    return Positioned(
      bottom: 80,
      left: 0,
      right: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSpeechStatus(),
          if (_lastError != null) _buildError(),
          if (_lastAiResponse != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: AiResponseCard(
                response: _lastAiResponse!,
                onClear: _clearAiResponse,
              ),
            ),
          if (showDetectionStats && _detectionStats != null)
            _buildDetectionStats(),
        ],
      ),
    );
  }

  Widget _buildSpeechStatus() {
    String text;
    if (_speechToText.isListening) {
      text = _lastWords.isEmpty ? 'Listening...' : _lastWords;
    } else if (_wakeListeningEnabled) {
      text = 'Say "Pathfinder" to start a command';
    } else {
      text = 'Tap mic to enable listening';
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildError() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.red.withAlpha(204),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _lastError!,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }

  Widget _buildDetectionStats() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(150),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children:
            _detectionStats!.entries
                .map((e) => StatsWidget(e.key, e.value))
                .toList(),
      ),
    );
  }

  Widget _buildFabs() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        FloatingActionButton(
          onPressed: _openSettings,
          heroTag: 'settings',
          tooltip: 'Settings',
          child: const Icon(Icons.settings),
        ),
        const SizedBox(height: 16),
        FloatingActionButton(
          onPressed: _toggleDetection,
          heroTag: 'detection',
          tooltip: _detectionEnabled ? 'Disable detection' : 'Enable detection',
          child: Icon(
            _detectionEnabled ? Icons.visibility : Icons.visibility_off,
          ),
        ),
        const SizedBox(height: 16),
        FloatingActionButton(
          onPressed: _toggleListening,
          heroTag: 'listening',
          tooltip: _wakeListeningEnabled ? 'Stop listening' : 'Start listening',
          child: Icon(
            _wakeListeningEnabled ? Icons.hearing : Icons.hearing_disabled,
          ),
        ),
      ],
    );
  }

  void _toggleListening() {
    if (_wakeListeningEnabled) {
      _stopListening();
    } else {
      _wakeListeningEnabled = true;
      _startListening();
    }
  }

  /// Starts or stops object detection and clears any on-screen boxes.
  void _toggleDetection() {
    setState(() {
      _detectionEnabled = !_detectionEnabled;
      if (!_detectionEnabled) {
        _recognitions = null;
        _detectionStats = null;
      }
    });
  }

  void _openSettings() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder:
            (_) => SettingsScreen(
              serverUrl: _serverUrl,
              ttsRate: _ttsRate,
              ttsPitch: _ttsPitch,
              ttsVolume: _ttsVolume,
              ttsLanguage: _ttsLanguage,
            ),
      ),
    );
    if (result != null) {
      await _saveSettings(
        serverUrl: result['serverUrl'] as String?,
        ttsRate: result['ttsRate'] as double?,
        ttsPitch: result['ttsPitch'] as double?,
        ttsVolume: result['ttsVolume'] as double?,
        ttsLanguage: result['ttsLanguage'] as String?,
      );
    }
  }
}

/// Screen for configuring the backend server URL and TTS parameters.
class SettingsScreen extends StatefulWidget {
  final String serverUrl;
  final double ttsRate;
  final double ttsPitch;
  final double ttsVolume;
  final String ttsLanguage;

  const SettingsScreen({
    required this.serverUrl,
    required this.ttsRate,
    required this.ttsPitch,
    required this.ttsVolume,
    required this.ttsLanguage,
    super.key,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _serverUrlController;
  late final TextEditingController _languageController;
  late double _ttsRate;
  late double _ttsPitch;
  late double _ttsVolume;

  @override
  void initState() {
    super.initState();
    _serverUrlController = TextEditingController(text: widget.serverUrl);
    _languageController = TextEditingController(text: widget.ttsLanguage);
    _ttsRate = widget.ttsRate;
    _ttsPitch = widget.ttsPitch;
    _ttsVolume = widget.ttsVolume;
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _languageController.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.of(context).pop<Map<String, dynamic>>({
      'serverUrl': _serverUrlController.text,
      'ttsRate': _ttsRate,
      'ttsPitch': _ttsPitch,
      'ttsVolume': _ttsVolume,
      'ttsLanguage':
          _languageController.text.isEmpty ? 'en-GB' : _languageController.text,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            const Text(
              'Text-to-Speech',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _languageController,
              decoration: const InputDecoration(
                labelText: 'Language',
                hintText: 'en-GB',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Text('Speech Rate: ${_ttsRate.toStringAsFixed(2)}'),
            Slider(
              value: _ttsRate,
              min: 0.5,
              max: 2.0,
              divisions: 30,
              label: _ttsRate.toStringAsFixed(2),
              onChanged: (v) => setState(() => _ttsRate = v),
            ),
            const SizedBox(height: 16),
            Text('Pitch: ${_ttsPitch.toStringAsFixed(2)}'),
            Slider(
              value: _ttsPitch,
              min: 0.5,
              max: 2.0,
              divisions: 30,
              label: _ttsPitch.toStringAsFixed(2),
              onChanged: (v) => setState(() => _ttsPitch = v),
            ),
            const SizedBox(height: 16),
            Text('Volume: ${_ttsVolume.toStringAsFixed(2)}'),
            Slider(
              value: _ttsVolume,
              min: 0.0,
              max: 1.0,
              divisions: 20,
              label: _ttsVolume.toStringAsFixed(2),
              onChanged: (v) => setState(() => _ttsVolume = v),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _save,
                child: const Text('Save Settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
