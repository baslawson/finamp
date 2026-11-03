import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SleepSound { rain, waves, pinkNoise, brownNoise, whiteNoise }

typedef SleepSoundSettings = ({SleepSound sound, double volume, bool followMusic});

/// Calming background sounds under the music, or on their own after the music stops. The sounds are generated
/// on the device, so there's nothing to download.
class SleepSoundsService {
  SleepSoundsService._();

  static const _sampleRate = 22050;
  static const _loopSeconds = 32;
  static const _prefix = "sleepSound";

  static final _player = AudioPlayer(handleInterruptions: false, handleAudioSessionActivation: false);
  static StreamSubscription<bool>? _musicSubscription;
  static SleepSoundSettings _settings = (sound: SleepSound.rain, volume: 0.5, followMusic: false);

  /// Whether a sound is on (it may be paused along with the music).
  static final playing = StreamController<bool>.broadcast();
  static bool isOn = false;

  static Future<SleepSoundSettings> loadSettings() async {
    final prefs = SharedPreferencesAsync();
    final sound = await prefs.getString("${_prefix}Sound");
    return _settings = (
      sound: SleepSound.values.firstWhere((value) => value.name == sound, orElse: () => SleepSound.rain),
      volume: await prefs.getDouble("${_prefix}Volume") ?? 0.5,
      followMusic: await prefs.getBool("${_prefix}FollowMusic") ?? false,
    );
  }

  static Future<void> saveSettings(SleepSoundSettings settings) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setString("${_prefix}Sound", settings.sound.name);
    await prefs.setDouble("${_prefix}Volume", settings.volume);
    await prefs.setBool("${_prefix}FollowMusic", settings.followMusic);
    final soundChanged = settings.sound != _settings.sound;
    _settings = settings;
    await _player.setVolume(settings.volume);
    if (isOn && soundChanged) await start();
    if (isOn) _followMusic();
  }

  static Future<void> start() async {
    final file = await _soundFile(_settings.sound);
    await _player.setFilePath(file.path);
    await _player.setLoopMode(LoopMode.one);
    await _player.setVolume(_settings.volume);
    isOn = true;
    playing.add(true);
    _followMusic();
    final musicPlaying = GetIt.instance<MusicPlayerBackgroundTask>().playbackState.value.playing;
    if (!_settings.followMusic || musicPlaying) unawaited(_player.play());
  }

  static Future<void> stop() async {
    isOn = false;
    playing.add(false);
    await _musicSubscription?.cancel();
    _musicSubscription = null;
    await _player.stop();
  }

  /// In follow mode the sound pauses and resumes with the music.
  static void _followMusic() {
    unawaited(_musicSubscription?.cancel());
    _musicSubscription = null;
    if (!_settings.followMusic) return;
    _musicSubscription = GetIt.instance<MusicPlayerBackgroundTask>().playbackState
        .map((state) => state.playing)
        .distinct()
        .listen((musicPlaying) => unawaited(musicPlaying ? _player.play() : _player.pause()));
  }

  static Future<File> _soundFile(SleepSound sound) async {
    final file = File("${(await getApplicationSupportDirectory()).path}/sleep_sounds/${sound.name}.wav");
    if (await file.exists()) return file;
    await file.parent.create(recursive: true);
    final pcm = await Isolate.run(() => generate(sound, seconds: _loopSeconds, sampleRate: _sampleRate));
    await file.writeAsBytes(AiService.wav(pcm, sampleRate: _sampleRate));
    return file;
  }

  /// 16-bit mono PCM of [sound] that loops seamlessly.
  static Uint8List generate(SleepSound sound, {required int seconds, required int sampleRate, int seed = 7}) {
    final random = Random(seed);
    final count = seconds * sampleRate;
    final samples = Float64List(count);

    // Pink noise filter state (Paul Kellet's refined method).
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0;
    double pink(double white) {
      b0 = 0.99886 * b0 + white * 0.0555179;
      b1 = 0.99332 * b1 + white * 0.0750759;
      b2 = 0.96900 * b2 + white * 0.1538520;
      b3 = 0.86650 * b3 + white * 0.3104856;
      b4 = 0.55000 * b4 + white * 0.5329522;
      b5 = -0.7616 * b5 - white * 0.0168980;
      final out = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362;
      b6 = white * 0.115926;
      return out * 0.11;
    }

    var brown = 0.0;
    var drop = 0.0;
    var dropDecay = 0.0;
    var lowPass = 0.0;
    for (var i = 0; i < count; i++) {
      final white = random.nextDouble() * 2 - 1;
      final t = i / sampleRate;
      switch (sound) {
        case SleepSound.whiteNoise:
          samples[i] = white * 0.3;
        case SleepSound.pinkNoise:
          samples[i] = pink(white);
        case SleepSound.brownNoise:
          brown = (brown + white * 0.02) * 0.998;
          samples[i] = brown * 3;
        case SleepSound.rain:
          // A soft hiss with drops landing at random.
          if (random.nextDouble() < 0.0025) {
            drop = 0.2 + random.nextDouble() * 0.5;
            dropDecay = 0.985 + random.nextDouble() * 0.01;
          }
          drop *= dropDecay;
          lowPass += 0.35 * (pink(white) - lowPass);
          samples[i] = lowPass * 0.8 + white * drop * 0.35;
        case SleepSound.waves:
          // Deep rumble that swells and recedes, four waves per loop.
          brown = (brown + white * 0.02) * 0.998;
          final swell = pow(sin(pi * t * 4 / seconds), 2).toDouble();
          samples[i] = (brown * 2.2 + pink(white) * 0.6) * (0.15 + 0.85 * swell);
      }
    }

    // Blend the last second into the first so the loop has no seam.
    final blend = sampleRate;
    for (var i = 0; i < blend; i++) {
      final mix = i / blend;
      samples[i] = samples[i] * mix + samples[count - blend + i] * (1 - mix);
    }
    final length = count - blend;
    final bytes = ByteData(length * 2);
    for (var i = 0; i < length; i++) {
      bytes.setInt16(i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    return bytes.buffer.asUint8List();
  }
}
