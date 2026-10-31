import 'dart:async';

import 'package:finamp/services/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("a voice failing for the app's own reason is logged with it", () {
    expect(
      AiService.speechFailure(AiException('Gemini returned an oversized speech recording')),
      'Gemini returned an oversized speech recording',
    );
  });

  test("what the provider sent, quoted in the app's own reason, is left out", () {
    expect(
      AiService.speechFailure(AiException('Gemini returned incomplete speech (https://example.com/secret)')),
      'Gemini returned incomplete speech',
    );
    expect(
      AiService.speechFailure(AiException('Gemini sent an answer that couldn\'t be read: body text')),
      "Gemini sent an answer that couldn't be read",
    );
  });

  test("a provider's error is logged by its status only, never its text", () {
    expect(
      AiService.speechFailure(AiException('Gemini error 500: something the server said', statusCode: 500)),
      'HTTP 500',
    );
  });

  test('a voice that took too long is logged as timed out', () {
    expect(AiService.speechFailure(AiException('Voice preparation timed out', timedOut: true)), 'timed out');
    expect(AiService.speechFailure(TimeoutException('slow')), 'timed out');
  });

  test('anything else is logged by its kind only', () {
    expect(AiService.speechFailure(const FormatException('body text')), 'FormatException');
  });
}
