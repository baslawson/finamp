import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../components/global_snackbar.dart';
import '../models/jellyfin_models.dart';
import 'downloads_service.dart';
import 'feedback_helper.dart';
import 'finamp_settings_helper.dart';
import 'jellyfin_api_helper.dart';

part 'favorite_provider.g.dart';

@riverpod
class IsFavorite extends _$IsFavorite {
  bool _changed = false;
  Future<void>? _initializing;

  @override
  bool build(BaseItemDto? item) {
    if (item == null) {
      return false;
    }
    ref.listen(finampSettingsProvider.isOffline, (_, value) {
      if (!_changed && value == false) {
        // If we have not had updateFavorite run and are moving from offline to
        // online, invalidate to fetch latest data from server.
        ref.invalidateSelf();
      }
    });

    if ((item.finampOffline ?? false) || item.userData?.isFavorite == null) {
      if (!FinampSettingsHelper.finampSettings.isOffline) {
        // Fetch the latest value from the server to replace the request's default value
        // as soon as possible.
        _initializing = Future.sync(() async {
          try {
            final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
            var newItem = await jellyfinApiHelper.getItemById(item.id);
            if (!_changed) {
              state = newItem.userData?.isFavorite ?? false;
            }
          } catch (e) {
            GlobalSnackbar.error(e);
          }
        });
      }
      // The favorites status in offline items is unreliable, use isFavorite instead
      // if possible.
      return GetIt.instance<DownloadsService>().isFavorite(item) ?? item.userData?.isFavorite ?? false;
    } else {
      return item.userData?.isFavorite ?? false;
    }
  }

  bool updateFavorite(bool isFavorite) {
    assert(item != null);
    final isOffline = FinampSettingsHelper.finampSettings.isOffline;
    final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
    final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
    final queueService = GetIt.instance<QueueService>();
    if (isOffline) {
      FeedbackHelper.feedback(FeedbackType.error);
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.notAvailableInOfflineMode);
      return state;
    }

    var oldState = state;
    // Once the favorite has been toggled, any existing BaseItemDtos may be out
    // of date, so we can never safely re-create the widget from a DefaultValue
    // and must keep it alive.
    ref.keepAlive();
    _changed = true;

    Future.sync(() async {
      try {
        UserItemDataDto newUserData;
        if (isFavorite) {
          newUserData = await jellyfinApiHelper.addFavorite(item!.id);
        } else {
          newUserData = await jellyfinApiHelper.removeFavorite(item!.id);
        }
        state = newUserData.isFavorite;

        FeedbackHelper.feedback(FeedbackType.heavy);
      } catch (e) {
        state = oldState;
        GlobalSnackbar.error(e);
      }
    });
    state = isFavorite;
    // If the current track is the one being toggled, update the playback state (and media notification)
    if (item!.id == queueService.getCurrentTrack()?.baseItem.id) {
      audioHandler.refreshPlaybackStateAndMediaNotification();
    }
    return state;
  }

  void updateState(bool isFavorite) {
    if (state != isFavorite) {
      // cache new state to override existing BaseItemDto data from queue
      _changed = true;
      ref.keepAlive();
    }
    state = isFavorite;
  }

  void toggleFavorite() async {
    if (_initializing != null) {
      await _initializing;
    }
    updateFavorite(!state);
  }
}

/// The current track's favourite, for the playback state the player sends many times a song. Listening keeps it loaded
/// while the track plays, rather than parsing the track again and (for downloaded tracks) asking the server anew each
/// time; [onChange] runs when it changes, so the notification shows it at once.
class CurrentFavorite {
  CurrentFavorite(this._container, this._onChange);
  final ProviderContainer _container;
  final void Function() _onChange;
  Object? _id;
  ProviderSubscription<bool>? _subscription;

  /// Whether the track with [itemJson] (a media item's "itemJson") is a favourite.
  bool read(Map<String, dynamic>? itemJson) {
    final id = itemJson?["Id"];
    if (itemJson == null || id == null) {
      close();
      return false;
    }
    if (id != _id || _subscription == null) {
      final previous = _subscription;
      _id = id;
      _subscription = _container.listen(isFavoriteProvider(BaseItemDto.fromJson(itemJson)), (_, _) => _onChange());
      // Closed after listening anew, so the same song's state isn't dropped in between.
      previous?.close();
    }
    return _subscription!.read();
  }

  void close() {
    _subscription?.close();
    _subscription = null;
    _id = null;
  }
}
