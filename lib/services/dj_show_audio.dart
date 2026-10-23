import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_recordings.dart';
import 'package:finamp/services/dj_voice_settings.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Only optional prepared voice clips pass through here. Music never does.
class DjShowAudio {
  static const sampleRate = 24000;
  static Uint8List pcm(List<int> input, {int maxSeconds = 45}) {
    if (input.length < 44 || input.length > 18 * 1024 * 1024) throw const FormatException('Invalid WAV size');
    final bytes = Uint8List.fromList(input);
    final data = ByteData.sublistView(bytes);
    String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') throw const FormatException('A PCM WAV recording is required');
    int? rate, channels;
    Uint8List? source;
    for (var at = 12; at + 8 <= bytes.length;) {
      final length = data.getUint32(at + 4, Endian.little), start = at + 8;
      if (length > bytes.length - start) throw const FormatException('Truncated WAV recording');
      if (tag(at) == 'fmt ') {
        if (length < 16 ||
            data.getUint16(start, Endian.little) != 1 ||
            data.getUint16(start + 14, Endian.little) != 16) {
          throw const FormatException('Use a 16-bit PCM WAV recording');
        }
        channels = data.getUint16(start + 2, Endian.little);
        rate = data.getUint32(start + 4, Endian.little);
        if ((channels != 1 && channels != 2) ||
            rate < 8000 ||
            rate > 96000 ||
            data.getUint16(start + 12, Endian.little) != channels * 2) {
          throw const FormatException('Unsupported WAV format');
        }
      } else if (tag(at) == 'data') {
        source = Uint8List.sublistView(bytes, start, start + length);
      }
      at = start + length + (length.isOdd ? 1 : 0);
    }
    if (rate == null || channels == null || source == null || source.isEmpty || source.length % (channels * 2) != 0) {
      throw const FormatException('Invalid PCM recording');
    }
    final frames = source.length ~/ (channels * 2);
    if (frames > rate * maxSeconds) throw const FormatException('Recording is too long');
    if (rate == sampleRate && channels == 1) return source;
    final samples = ByteData.sublistView(source), count = (frames * sampleRate / rate).round();
    final result = ByteData(count * 2);
    double sample(int frame) {
      var value = 0.0;
      for (var channel = 0; channel < channels!; channel++) {
        value += samples.getInt16((frame * channels + channel) * 2, Endian.little);
      }
      return value / channels;
    }

    for (var frame = 0; frame < count; frame++) {
      final position = frame * rate / sampleRate, a = min(frames - 1, position.floor()), b = min(frames - 1, a + 1);
      final value = sample(a) + (sample(b) - sample(a)) * (position - a);
      result.setInt16(frame * 2, value.round().clamp(-32768, 32767), Endian.little);
    }
    return result.buffer.asUint8List();
  }

  static List<int> join(List<List<int>> recordings) {
    final parts = recordings.map((v) => pcm(v)).toList();
    final silence = Uint8List(sampleRate * 2 * 120 ~/ 1000);
    final length = parts.fold<int>(0, (n, v) => n + v.length) + max(0, parts.length - 1) * silence.length;
    if (parts.isEmpty || length > sampleRate * 2 * 45) throw const FormatException('Announcement is too long');
    final result = BytesBuilder(copy: false);
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) result.add(silence);
      result.add(parts[i]);
    }
    return AiService.wav(result.takeBytes(), sampleRate: sampleRate);
  }

  static Future<List<int>> joinAsync(List<List<int>> recordings) => Isolate.run(() => join(recordings));
  static List<int> jingle(List<int> bytes) {
    final pcm = DjShowAudio.pcm(bytes, maxSeconds: 12);
    final samples = ByteData.sublistView(pcm);
    final frames = pcm.length ~/ 2, edge = min(120, pcm.length ~/ 4);
    // Imported recordings can start or end away from zero. A 5 ms edge ramp
    // prevents a click at that boundary; announcement samples stay intact.
    for (var i = 0; i < edge; i++) {
      final gain = i / edge;
      for (final frame in [i, frames - 1 - i]) {
        samples.setInt16(frame * 2, (samples.getInt16(frame * 2, Endian.little) * gain).round(), Endian.little);
      }
    }
    return AiService.wav(pcm, sampleRate: sampleRate);
  }
}

/// Jingles are copied into the app's account-scoped storage, never referenced
/// by an external file path. Existing queue, downloads and music are untouched.
class DjJingleStore {
  static final _id = RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$');
  static Future<Directory> _root(String scope) async =>
      Directory('${(await getApplicationSupportDirectory()).path}/dj-jingles/${sha256.convert(utf8.encode(scope))}');
  static Future<String> save(List<int> bytes, {String? scope}) async {
    if (bytes.length > 2 * 1024 * 1024) throw const FormatException('Jingles must be 2 MB or smaller');
    final capturedScope = scope ?? RadioPreferencesStore.scope;
    final wav = await Isolate.run(() => DjShowAudio.jingle(bytes));
    final root = await _root(capturedScope);
    await root.create(recursive: true);
    final id = const Uuid().v4();
    await File('${root.path}/$id.wav').writeAsBytes(wav, flush: true);
    return id;
  }

  static Future<List<int>?> read(String id, {String? scope}) async {
    if (!_id.hasMatch(id)) return null;
    try {
      final root = await _root(scope ?? RadioPreferencesStore.scope), file = File('${root.path}/$id.wav');
      if (await file.length() > 2 * 1024 * 1024) return null;
      final bytes = await file.readAsBytes();
      DjShowAudio.pcm(bytes, maxSeconds: 12);
      return bytes;
    } on Object {
      return null;
    }
  }

  static Future<void> remove(String id, {String? scope}) async {
    if (!_id.hasMatch(id)) return;
    final root = await _root(scope ?? RadioPreferencesStore.scope), file = File('${root.path}/$id.wav');
    if (await file.exists()) await file.delete();
  }
}

class DjShowTurn {
  const DjShowTurn(this.character, this.text);
  final DjVoiceCharacter character;
  final String text;
}

/// Prepare the whole exchange before playback. A missing co-host or jingle
/// falls back to the successful main recording; cancellation discards all work.
class DjShowBuilder {
  static Future<DjAudioClip?> prepare({
    required DjShowTurn main,
    DjShowTurn? reply,
    List<int>? jingle,
    required Future<File?> Function(DjShowTurn turn) record,
    required bool Function() wanted,
  }) async {
    final files = <File>[];
    File? retained;
    Future<File?>? pendingReply;
    try {
      if (!wanted()) return null;
      // Both hosts are recorded at the same time rather than one after the other; the main host is asked first.
      final mainRecording = record(main);
      pendingReply = reply == null ? null : record(reply).then<File?>((file) => file, onError: (Object _) => null);
      final first = await mainRecording;
      if (first == null) return null;
      files.add(first);
      if (!wanted()) return null;
      final recordings = <List<int>>[await first.readAsBytes()];
      List<int>? joined;
      var text = main.text;
      if (reply != null) {
        try {
          final second = await pendingReply;
          pendingReply = null;
          if (second != null) {
            files.add(second);
            if (!wanted()) return null;
            final bytes = await second.readAsBytes();
            // Validate the combined length before accepting a co-host.
            joined = await DjShowAudio.joinAsync([...recordings, bytes]);
            recordings.add(bytes);
            text = '${main.text}\n${reply.text}';
          }
        } on Object {
          /* The main host is already ready. */
        }
      }
      if (!wanted()) return null;
      if (jingle != null) {
        try {
          joined = await DjShowAudio.joinAsync([jingle, ...recordings]);
          recordings.insert(0, jingle);
        } on FormatException {
          /* Ignore a missing, damaged or overlong jingle. */
        }
      }
      if (!wanted()) return null;
      if (recordings.length == 1) {
        retained = first;
        return DjAudioClip(first, text);
      }
      final output = File('${first.parent.path}/dj-show-${const Uuid().v4()}.wav');
      files.add(output);
      await output.writeAsBytes(joined!);
      if (!wanted()) return null;
      retained = output;
      return DjAudioClip(output, text);
    } finally {
      // A co-host still being recorded when the line was dropped is removed once it's done (it stops early itself
      // when the line is no longer wanted).
      final orphan = await pendingReply;
      if (orphan != null) await DjReplayStore.discard(orphan);
      for (final file in files) {
        if (file.path != retained?.path) await DjReplayStore.discard(file);
      }
    }
  }
}
