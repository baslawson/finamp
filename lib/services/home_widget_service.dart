import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

/// Keeps the Android now playing home screen widget in sync with the player.
class HomeWidgetService {
  HomeWidgetService._();

  static const _channel = MethodChannel("com.unicornsonlsd.finamp/home_widget");
  static final _logger = Logger("HomeWidgetService");

  static void start(BaseAudioHandler audioHandler) {
    if (!Platform.isAndroid) return;
    Rx.combineLatest2(
          audioHandler.mediaItem,
          audioHandler.playbackState.map((state) => state.playing),
          (MediaItem? item, bool playing) => (title: item?.title, artist: item?.artist, playing: playing),
        )
        .distinct()
        .listen((state) async {
          try {
            await _channel.invokeMethod("update", {
              "title": state.title,
              "artist": state.artist,
              "playing": state.playing,
            });
          } on PlatformException catch (e) {
            _logger.warning("Updating the home screen widget failed", e);
          } on MissingPluginException {
            // The activity that registers the channel isn't attached, e.g. while the app starts in the background.
          }
        });
  }
}
