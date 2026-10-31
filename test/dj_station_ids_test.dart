import 'dart:io';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_station_ids.dart';
import 'package:finamp/services/dj_voice_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferencesAsyncPlatform? previous;
  final recorded = <String>[];

  setUp(() async {
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    directory = await Directory.systemTemp.createTemp('station-ids');
    DjStationIds.reset();
    DjStationIds.root = () async => Directory('${directory.path}/ids');
    recorded.clear();
  });
  tearDown(() async {
    SharedPreferencesAsyncPlatform.instance = previous;
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Windows can hold a just-deleted recording open for a moment.
    }
  });

  Future<File?> record(String text) async {
    recorded.add(text);
    return File(
      '${directory.path}/rec-${recorded.length}.wav',
    ).writeAsBytes(AiService.wav(List<int>.filled(24000, 0), sampleRate: 24000));
  }

  Future<List<int>?> pick({DjVoiceCharacter character = DjVoiceCharacter.chill}) =>
      DjStationIds.pick(character, 'Night Owl FM', record: record);

  test('the first ask records one station ID in the background; later asks reuse saved ones', () async {
    expect(await pick(), isNull);
    await DjStationIds.waitForRecording();
    expect(recorded, ["You're listening to Night Owl FM."]);
    expect(await pick(), isNotNull);
    await DjStationIds.waitForRecording();
    await pick();
    await DjStationIds.waitForRecording();
    await pick();
    await DjStationIds.waitForRecording();
    expect(recorded, hasLength(3), reason: 'each phrasing is recorded once');
    expect(directory.listSync().whereType<File>().where((f) => f.path.contains('rec-')), isEmpty);
  });

  test('each voice has its own station IDs', () async {
    await pick();
    await DjStationIds.waitForRecording();
    expect(await pick(character: DjVoiceCharacter.energetic), isNull);
  });

  test('a failed recording is tried again later', () async {
    var fail = true;
    Future<File?> flaky(String text) async {
      if (fail) throw const SocketException('offline');
      return record(text);
    }

    expect(await DjStationIds.pick(DjVoiceCharacter.chill, 'X', record: flaky), isNull);
    await DjStationIds.waitForRecording();
    fail = false;
    await DjStationIds.pick(DjVoiceCharacter.chill, 'X', record: flaky);
    await DjStationIds.waitForRecording();
    expect(await DjStationIds.pick(DjVoiceCharacter.chill, 'X', record: flaky), isNotNull);
  });

  test('turned off, nothing is recorded or played', () async {
    await DjStationIds.setEnabled(false);
    expect(await pick(), isNull);
    await DjStationIds.waitForRecording();
    expect(recorded, isEmpty);
  });
}
