import 'package:finamp/services/censored_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  test("a logged error is kept after its message", () {
    final record = LogRecord(Level.INFO, "Couldn't open the party on the server hub", "PartyService", "Timed out");
    expect(record.censoredMessage, endsWith("Couldn't open the party on the server hub: Timed out"));
  });

  test("an error the message already includes isn't repeated", () {
    final record = LogRecord(Level.SEVERE, "Player error: Source error", "Player", "Source error");
    expect(record.censoredMessage, endsWith(": Player error: Source error"));
  });

  test("a message without an error is unchanged", () {
    final record = LogRecord(Level.INFO, "Party mode on", "PartyService");
    expect(record.censoredMessage, endsWith(": Party mode on"));
  });
}
