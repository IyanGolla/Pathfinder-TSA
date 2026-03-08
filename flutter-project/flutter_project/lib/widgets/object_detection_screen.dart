import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

import '../services/object_detector_service.dart';

class _ObjectBoundingBoxPainter extends CustomPainter {
  final List<DetectedObject> objects;
  final Size imageSize;
  final CameraLensDirection lensDirection;

  _ObjectBoundingBoxPainter({
    required this.objects,
    required this.imageSize,
    required this.lensDirection,
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
  bool shouldRepaint(_ObjectBoundingBoxPainter oldDelegate) =>
      oldDelegate.objects != objects || oldDelegate.imageSize != imageSize;
}

class ObjectDetectionScreen extends StatefulWidget {
  const ObjectDetectionScreen({super.key});

  @override
  State<ObjectDetectionScreen> createState() => _ObjectDetectionScreenState();
}

class _ObjectDetectionScreenState extends State<ObjectDetectionScreen> {
  CameraController? _controller;
  bool _isInitialized = false;
  bool _isBusy = false;

  final _service = ObjectDetectorService();
  List<DetectedObject> _detectedObjects = [];
  Size _imageSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _service.initialize();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid
              ? ImageFormatGroup.nv21
              : ImageFormatGroup.bgra8888,
    );

    await _controller!.initialize();

    if (!mounted) return;

    await _controller!.startImageStream(_onCameraImage);

    setState(() => _isInitialized = true);
  }

  void _onCameraImage(CameraImage image) {
    print("Received camera image for processing");
    if (_isBusy) return;
    _isBusy = true;

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      _isBusy = false;
      return;
    }

    print(
      "controller is not null and initialized, proceeding with image processing",
    );

    final inputImage = _service.inputImageFromCameraImage(
      image,
      controller.description,
      controller.value.deviceOrientation,
    );

    if (inputImage == null) {
      _isBusy = false;
      return;
    }

    _service
        .processImage(inputImage)
        .then((objects) {
          if (mounted) {
            setState(() {
              _detectedObjects = objects;
              _imageSize = Size(
                image.width.toDouble(),
                image.height.toDouble(),
              );
            });
          }
          _isBusy = false;
        })
        .catchError((_) {
          _isBusy = false;
        });
  }

  @override
  void dispose() {
    _controller?.stopImageStream();
    _controller?.dispose();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Object Detection')),
      body:
          _isInitialized && _controller != null
              ? _buildCameraWithOverlay()
              : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildCameraWithOverlay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(_controller!),
            if (_detectedObjects.isNotEmpty && _imageSize != Size.zero)
              CustomPaint(
                painter: _ObjectBoundingBoxPainter(
                  objects: _detectedObjects,
                  imageSize: _imageSize,
                  lensDirection: _controller!.description.lensDirection,
                ),
              ),
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
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
