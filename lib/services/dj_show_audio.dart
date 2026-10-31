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

/// A jingle or chime the voice is read over ([DjShowAudio.talkOver]): [roll] (0 to 1) picks where the voice comes in,
/// and [under] is the bed's volume under it (0 to 1).
typedef DjBed = ({List<int> sound, double roll, double under});

/// Only optional prepared voice clips pass through here. Music never does.
class DjShowAudio {
  static const sampleRate = 24000;
  static Uint8List pcm(List<int> input, {int maxSeconds = 45}) {
    if (input.length < 44 || input.length > 18 * 1024 * 1024) throw const FormatException('Invalid WAV size');
    final bytes = Uint8List.fromList(input);
    final data = ByteData.sublistView(bytes);
    String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') throw const FormatException('A PCM WAV recording is required');
    int? rate, channels, bits;
    var float = false;
    Uint8List? source;
    for (var at = 12; at + 8 <= bytes.length;) {
      final length = data.getUint32(at + 4, Endian.little), start = at + 8;
      if (length > bytes.length - start) throw const FormatException('Truncated WAV recording');
      if (tag(at) == 'fmt ') {
        if (length < 16) throw const FormatException('Invalid PCM recording');
        var format = data.getUint16(start, Endian.little);
        // Extensible WAVs (as editors save 24-bit ones) give the real format in their subformat.
        if (format == 0xFFFE) format = length < 40 ? 0 : data.getUint16(start + 24, Endian.little);
        bits = data.getUint16(start + 14, Endian.little);
        float = format == 3;
        if (!(format == 1 && (bits == 16 || bits == 24)) && !(float && bits == 32)) {
          throw const FormatException('Use a 16- or 24-bit PCM, or 32-bit float, WAV recording');
        }
        channels = data.getUint16(start + 2, Endian.little);
        rate = data.getUint32(start + 4, Endian.little);
        if ((channels != 1 && channels != 2) ||
            rate < 8000 ||
            rate > 96000 ||
            data.getUint16(start + 12, Endian.little) != channels * bits ~/ 8) {
          throw const FormatException('Unsupported WAV format');
        }
      } else if (tag(at) == 'data') {
        source = Uint8List.sublistView(bytes, start, start + length);
      }
      at = start + length + (length.isOdd ? 1 : 0);
    }
    final width = (bits ?? 16) ~/ 8;
    if (rate == null ||
        channels == null ||
        source == null ||
        source.isEmpty ||
        source.length % (channels * width) != 0) {
      throw const FormatException('Invalid PCM recording');
    }
    final frames = source.length ~/ (channels * width);
    if (frames > rate * maxSeconds) throw const FormatException('Recording is too long');
    if (rate == sampleRate && channels == 1 && width == 2 && !float) return source;
    final samples = ByteData.sublistView(source), count = (frames * sampleRate / rate).round();
    final result = ByteData(count * 2);
    // One channel's sample, on the 16-bit scale.
    double one(int at) {
      if (float) return samples.getFloat32(at, Endian.little) * 32767;
      if (width == 2) return samples.getInt16(at, Endian.little).toDouble();
      final value = samples.getUint8(at) | samples.getUint8(at + 1) << 8 | samples.getInt8(at + 2) << 16;
      return value / 256;
    }

    double sample(int frame) {
      var value = 0.0;
      for (var channel = 0; channel < channels!; channel++) {
        value += one((frame * channels + channel) * width);
      }
      return value / channels;
    }

    final shrinking = rate > sampleRate;
    for (var frame = 0; frame < count; frame++) {
      double value;
      if (shrinking) {
        // Down to fewer samples, each is the average of the stretch of them it stands for (the ones at its edges
        // counted for the part inside it), so high sounds don't fold back as a harsh ring.
        final start = frame * rate / sampleRate, end = (frame + 1) * rate / sampleRate;
        value = 0;
        var weight = 0.0;
        for (var at = start.floor(); at < end && at < frames; at++) {
          final part = min(end, at + 1.0) - max(start, at.toDouble());
          value += sample(at) * part;
          weight += part;
        }
        value = weight > 0 ? value / weight : sample(frames - 1);
      } else {
        final position = frame * rate / sampleRate, a = min(frames - 1, position.floor()), b = min(frames - 1, a + 1);
        value = sample(a) + (sample(b) - sample(a)) * (position - a);
      }
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

  /// The shortest jingle or chime a voice is read over.
  static const talkOverMinimum = Duration(seconds: 3);

  /// Where in [bed] (a jingle or chime) a voice could come in over it: one of its quieter moments, picked by [roll]
  /// (0 to 1), never in its first second, its last half second, or the last second before its sound dies away. Null
  /// when it's too short for that.
  static Duration? talkOverPoint(List<int> bed, double roll) {
    final samples = ByteData.sublistView(pcm(bed, maxSeconds: 12)), frames = samples.lengthInBytes ~/ 2;
    if (frames < sampleRate * talkOverMinimum.inSeconds) return null;
    // Its loudness in 50 ms steps.
    const step = sampleRate ~/ 20, second = sampleRate ~/ step;
    final levels = <double>[];
    for (var from = 0; from + step <= frames; from += step) {
      var sum = 0.0;
      for (var i = from; i < from + step; i++) {
        final sample = samples.getInt16(i * 2, Endian.little);
        sum += sample * sample;
      }
      levels.add(sum / step);
    }
    final loudest = levels.fold(0.0, max);
    if (loudest == 0) return null;
    // Past where its sound ends (30 dB down) there's only a fade or silence to talk over.
    final sound = levels.lastIndexWhere((level) => level > loudest / 1000) + 1;
    final last = min(sound - second, (frames - sampleRate ~/ 2) ~/ step);
    if (last <= second) return null;
    final steps = [for (var i = second; i < last; i++) i]..sort((a, b) => levels[a].compareTo(levels[b]));
    final quiet = steps.sublist(0, max(1, steps.length ~/ 3));
    return Duration(
      microseconds: quiet[(roll * quiet.length).floor().clamp(0, quiet.length - 1)] * step * 1000000 ~/ sampleRate,
    );
  }

  /// [voice] read over [bed] from [at], as a newsreader talks over a news bed: [bed] dips to [under] of its volume over
  /// the 250 ms before, and comes back up over 400 ms should it outlast the voice. Where they overlap, a gentle limit
  /// keeps the two together from clipping.
  static List<int> overlay(List<int> bed, List<int> voice, {required Duration at, double under = 0.25}) {
    final music = ByteData.sublistView(pcm(bed, maxSeconds: 12)), words = ByteData.sublistView(pcm(voice));
    final bedFrames = music.lengthInBytes ~/ 2, voiceFrames = words.lengthInBytes ~/ 2;
    final start = (at.inMicroseconds * sampleRate ~/ 1000000).clamp(0, bedFrames), end = start + voiceFrames;
    final frames = max(bedFrames, end);
    if (frames > sampleRate * 45) throw const FormatException('Announcement is too long');
    const dip = sampleRate * 250 ~/ 1000, rise = sampleRate * 400 ~/ 1000;
    // A smooth step from 0 to 1 as [t] goes from 0 to 1.
    double ease(double t) => (1 - cos(pi * t.clamp(0.0, 1.0))) / 2;
    final result = ByteData(frames * 2);
    for (var frame = 0; frame < frames; frame++) {
      var value = 0.0;
      if (frame < bedFrames) {
        final gain = frame < end
            ? 1 - (1 - under) * ease((frame - (start - dip)) / dip)
            : under + (1 - under) * ease((frame - end) / rise);
        value = music.getInt16(frame * 2, Endian.little) * gain;
      }
      if (frame >= start && frame < end) {
        final word = words.getInt16((frame - start) * 2, Endian.little);
        value = frame < bedFrames ? _limit(value + word) : word.toDouble();
      }
      result.setInt16(frame * 2, value.round().clamp(-32768, 32767), Endian.little);
    }
    return AiService.wav(result.buffer.asUint8List(), sampleRate: sampleRate);
  }

  /// [value] as it is up to a knee, then eased towards full scale rather than clipped.
  static double _limit(double value) {
    const knee = 24000.0, room = 32767 - knee;
    if (value.abs() <= knee) return value;
    final over = 2 * (value.abs() - knee) / room, eased = knee + room * (1 - 2 / (exp(over) + 1));
    return value.isNegative ? -eased : eased;
  }

  /// [voice] read over [bed] at a [talkOverPoint] ([overlay]), and where in that the words start; null when [bed] is
  /// too short to talk over.
  static ({List<int> wav, Duration lead})? talkOver(DjBed bed, List<int> voice) {
    final at = talkOverPoint(bed.sound, bed.roll);
    return at == null ? null : (wav: overlay(bed.sound, voice, at: at, under: bed.under), lead: at);
  }

  static Future<({List<int> wav, Duration lead})?> talkOverAsync(DjBed bed, List<int> voice) =>
      Isolate.run(() => talkOver(bed, voice));

  /// How far into a [join] of [lead] and more the next recording starts: [lead]'s sound and the pause after it.
  static Duration startAfter(List<int> lead) =>
      Duration(microseconds: (pcm(lead).length + sampleRate * 2 * 120 ~/ 1000) * 1000000 ~/ (sampleRate * 2));
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

  /// The largest recording imported as a jingle or the news chime: 12 seconds of 48 kHz 24-bit stereo, and a little.
  static const maxImport = 5 * 1024 * 1024;

  static Future<String> save(List<int> bytes, {String? scope}) async {
    if (bytes.length > maxImport) throw const FormatException('Jingles must be 5 MB or smaller');
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
    DjBed? bed,
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
      var lead = Duration.zero;
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
      var opening = jingle, parts = recordings;
      // The words read over [bed], after [jingle], if any.
      if (bed != null) {
        ({List<int> wav, Duration lead})? over;
        try {
          over = await DjShowAudio.talkOverAsync(bed, joined ?? recordings.first);
        } on FormatException {
          /* A damaged one, or too long together: as if too short. */
        }
        if (over != null) {
          parts = [over.wav];
          joined = over.wav;
          lead = over.lead;
        } else {
          // One too short to talk over plays before the words instead.
          try {
            opening = opening == null ? bed.sound : await DjShowAudio.joinAsync([opening, bed.sound]);
          } on FormatException {
            /* The jingle alone, then. */
          }
        }
      }
      if (!wanted()) return null;
      if (opening != null) {
        try {
          joined = await DjShowAudio.joinAsync([opening, ...parts]);
          lead += DjShowAudio.startAfter(opening);
        } on FormatException {
          /* Ignore a missing, damaged or overlong jingle. */
        }
      }
      if (!wanted()) return null;
      if (joined == null) {
        retained = first;
        return DjAudioClip(first, text);
      }
      final output = File('${first.parent.path}/dj-show-${const Uuid().v4()}.wav');
      files.add(output);
      await output.writeAsBytes(joined);
      if (!wanted()) return null;
      retained = output;
      return DjAudioClip(output, text, lead: lead);
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
