import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:finamp/services/queue_reserve_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'fixtures/reserve_hls.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native HLS and Opus sources play and seek from reserve after the server disconnects', (tester) async {
    final root = await Directory((await getTemporaryDirectory()).path).createTemp('reserve-playback-');
    final cache = QueueReserveCache(root);
    final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = Uri.parse('http://127.0.0.1:${remote.port}');
    remote.listen((request) async {
      if (request.uri.path.endsWith('.m3u8')) {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        request.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.5,\ntone.ts\n#EXT-X-ENDLIST\n');
      } else {
        request.response.headers.contentType = ContentType('audio', 'ogg');
        request.response.add(base64Decode(request.uri.path.endsWith('.ts') ? reserveHlsTsBase64 : reserveOpusBase64));
      }
      await request.response.close();
    });
    final player = AudioPlayer();
    try {
      const hlsKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const opusKey = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final hlsSource = await cache.source(hlsKey, base.resolve('/main.m3u8'));
      final opusSource = await cache.source(opusKey, base.resolve('/music.ogg'));
      const redirectKey = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final redirectSource = await cache.source(redirectKey, base.resolve('/main.m3u8'));
      await player.setAudioSource(AudioSource.uri(redirectSource)).timeout(const Duration(seconds: 20));
      unawaited(player.play());
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(player.processingState, ProcessingState.ready);
      expect(player.position, greaterThan(const Duration(milliseconds: 300)));
      await player.stop();
      expect(await cache.download(hlsKey, base.resolve('/main.m3u8'), wanted: () => true), true);
      expect(await cache.download(opusKey, base.resolve('/music.ogg'), wanted: () => true), true);
      await remote.close(force: true);
      await player.setAudioSource(AudioSource.uri(hlsSource)).timeout(const Duration(seconds: 20));
      expect(player.duration, greaterThan(const Duration(seconds: 2)));
      await player.seek(const Duration(milliseconds: 600));
      unawaited(player.play());
      await player.processingStateStream
          .firstWhere((v) => v == ProcessingState.completed)
          .timeout(const Duration(seconds: 12));
      await player.setAudioSource(AudioSource.uri(opusSource)).timeout(const Duration(seconds: 20));
      await player.seek(const Duration(seconds: 2));
      unawaited(player.play());
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(player.processingState, ProcessingState.ready);
      expect(player.position, greaterThan(const Duration(seconds: 3)));
    } finally {
      await player.dispose();
      await cache.close();
      await remote.close(force: true);
      await root.delete(recursive: true);
    }
  });
}
