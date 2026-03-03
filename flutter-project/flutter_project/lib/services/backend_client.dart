import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

// HTTP client for talking to the backend proxy.
class BackendClient {
  BackendClient({
    this.baseUrl = 'http://localhost:8080/api/openai-proxy',
    this.streamUrl = 'http://localhost:8080/api/openai-proxy-stream',
  });

  final String baseUrl;
  final String streamUrl;

  // Optional stored session id returned by the backend.
  // If set, subsequent requests will include it so the backend can maintain conversation memory.
  String? sessionId;

  // Sends user text and an image to the backend and returns the extracted reply.
  Future<String> sendTextAndImage({
    required String text,
    required Uint8List imageBytes,
  }) async {
    final uri = Uri.parse(baseUrl);
    final bodyMap = {'text': text, 'image_base64': base64Encode(imageBytes)};
    if (sessionId != null) bodyMap['sessionId'] = sessionId!;
    final payload = json.encode(bodyMap);

    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: payload,
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Error ${resp.statusCode}: ${resp.body}');
    }

    final data = json.decode(resp.body);

    //If the backend returns our new simplified shape { sessionId, reply, raw }
    if (data is Map && data['reply'] != null) {
      if (data['sessionId'] != null) {
        sessionId = data['sessionId'] as String;
      }
      final reply = data['reply'];
      if (reply is String) return reply;
      return json.encode(reply);
    }

    // If the backend returns OpenAI "responses" style payloads.
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

  // Streams the model's reply text back as it is generated.
  // Current default model seems to return everything in one chunk, so this doesn't change much
  // TODO: Find a model that does stream longer responses
  Stream<String> streamTextAndImage({
    required String text,
    required Uint8List imageBytes,
  }) async* {
    final uri = Uri.parse(streamUrl);
    final bodyMap = {'text': text, 'image_base64': base64Encode(imageBytes)};
    if (sessionId != null) bodyMap['sessionId'] = sessionId!;
    final payload = json.encode(bodyMap);

    final client = http.Client();
    try {
      final request =
          http.Request('POST', uri)
            ..headers['Content-Type'] = 'application/json'
            ..body = payload;

      final response = await client.send(request);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw Exception('Error ${response.statusCode}: $body');
      }

      // Forward decoded UTF‑8 chunks as they arrive.
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        if (chunk.isNotEmpty) {
          yield chunk;
        }
      }
    } finally {
      client.close();
    }
  }
}
