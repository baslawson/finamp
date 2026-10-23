import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

bool karaokeCopyInUse(BaseItemDto item) {
  final services = GetIt.instance;
  if (!services.isRegistered<MusicPlayerBackgroundTask>() || !services<MusicPlayerBackgroundTask>().karaokeActive) {
    return false;
  }
  return !services.isRegistered<QueueService>() || services<QueueService>().getCurrentTrack()?.baseItem.id == item.id;
}

Future<bool> confirmKaraokeDeletion(BuildContext context, BaseItemDto item, {required bool server}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(server ? context.l10n.karaokeDeleteServer : context.l10n.karaokeDeletePhone),
        content: Text(
          server
              ? context.l10n.karaokeDeleteServerPrompt(item.name ?? context.l10n.karaoke)
              : context.l10n.karaokeDeletePhonePrompt(item.name ?? context.l10n.karaoke),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.genericCancel)),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(server ? context.l10n.karaokeDeleteServer : context.l10n.karaokeDeletePhone),
          ),
        ],
      ),
    ) ??
    false;
