import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thin HTTP client for talking to the local backend proxy.
class BackendClient {
  const BackendClient({
    this.baseUrl = 'http://localhost:8080/api/openai-proxy',
  });

  final String baseUrl;

  /// Sends user text and an image to the backend and returns the extracted reply.
  Future<String> sendTextAndImage({
    required String text,
    required Uint8List imageBytes,
  }) async {
    final uri = Uri.parse(baseUrl);
    final payload = json.encode({
      'text': text,
      'image_base64': base64Encode(imageBytes),
    });

    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: payload,
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Error ${resp.statusCode}: ${resp.body}');
    }

    final data = json.decode(resp.body);

    // Handle OpenAI "responses" style payloads.
    if (data is Map && data['output'] != null) {
      final output = data['output'];
      final buffer = StringBuffer();
      if (output is List) {
        for (final item in output) {
          if (item is Map && item['content'] != null) {
            final content = item['content'];
            if (content is List) {
              for (final c in content) {
                if (c is Map &&
                    c['type'] == 'output_text' &&
                    c['text'] != null) {
                  buffer.writeln(c['text']);
                }
              }
            } else if (content is String) {
              buffer.writeln(content);
            }
          }
        }
      }
      final result = buffer.toString().trim();
      if (result.isNotEmpty) return result;
    }

    // Fallback for classic chat/completions style payloads.
    if (data is Map && data['choices'] != null) {
      final buffer = StringBuffer();
      for (final ch in data['choices']) {
        if (ch is Map) {
          if (ch['text'] != null) {
            buffer.write(ch['text']);
          } else if (ch['message'] != null &&
              ch['message']['content'] != null) {
            buffer.write(ch['message']['content']);
          }
        }
      }
      final result = buffer.toString().trim();
      if (result.isNotEmpty) return result;
    }

    // If we couldn't interpret the structure, return the raw body.
    return resp.body;
  }
}

