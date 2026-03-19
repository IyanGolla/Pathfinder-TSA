import '../models/recognition.dart';

/// Decides which detected objects should trigger a spoken alert.
/// Filters by [relevantLabels], applies a per-label cooldown, and
/// ranks by proximity then confidence.
class ObjectAlertService {
  /// How long before the same label can be re-announced.
  final Duration cooldown;

  /// Minimum confidence to consider an object alert-worthy.
  final double minConfidence;

  /// Minimum bounding-box area fraction (relative to the 300×300 model input,
  /// i.e. 90 000 px²) to consider an object "close enough" to mention.
  /// 0.02 = 2 % of the frame.
  final double minProximity;

  /// Tracks the last time each label was announced.
  final Map<String, DateTime> _lastAlerted = {};

  ObjectAlertService({
    this.cooldown = const Duration(seconds: 10),
    this.minConfidence = 0.6,
    this.minProximity = 0.02,
  });

  /// Area of the full model input frame (300 × 300).
  static const double _frameArea = 300.0 * 300.0;

  /// mobilenetv1 labels worth alerting about, grouped by category.
  static const Set<String> relevantLabels = {
    // People
    'person',
    // Vehicles
    'bicycle', 'car', 'motorcycle', 'bus', 'train', 'truck', 'boat',
    // Traffic and street objects
    'traffic light', 'fire hydrant', 'stop sign', 'parking meter',
    // Animals
    'dog', 'cat', 'horse', 'cow', 'bear',
    // Furniture & large obstacles
    'bench', 'chair', 'couch', 'bed', 'dining table', 'desk',
    'potted plant', 'suitcase',
    // Interior features
    'door', 'window',
    // Room-identifying objects
    'toilet', 'sink', 'refrigerator', 'oven', 'microwave',
    // Useful items
    'tv', 'laptop', 'clock',
  };

  /// Returns labels that should be announced now (closest first).
  List<String> getNewAlerts(List<Recognition> recognitions) {
    final now = DateTime.now();
    final candidates = <_Candidate>[];

    for (final r in recognitions) {
      if (r.score < minConfidence) continue;

      final area = r.location.width * r.location.height;
      final proximity = area / _frameArea;
      if (proximity < minProximity) continue;

      final label = r.label.trim();
      if (label.isEmpty || !relevantLabels.contains(label)) continue;

      // Skip if recently alerted
      final last = _lastAlerted[label];
      if (last != null && now.difference(last) < cooldown) continue;

      candidates.add(_Candidate(label, proximity, r.score));
    }

    // Sort: highest proximity first (closest objects), break ties by confidence.
    candidates.sort((a, b) {
      final cmp = b.proximity.compareTo(a.proximity);
      return cmp != 0 ? cmp : b.confidence.compareTo(a.confidence);
    });

    // Deduplicate labels (keep first / highest-priority occurrence).
    final seen = <String>{};
    final alerts = <String>[];
    for (final c in candidates) {
      if (seen.add(c.label)) {
        alerts.add(c.label);
        _lastAlerted[c.label] = now;
      }
    }

    return alerts;
  }

  /// Reset all cooldowns (e.g. when the user moves to a new scene).
  void reset() => _lastAlerted.clear();
}

class _Candidate {
  final String label;
  final double proximity;
  final double confidence;
  _Candidate(this.label, this.proximity, this.confidence);
}
