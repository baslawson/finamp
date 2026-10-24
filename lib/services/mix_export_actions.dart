import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/playlist_actions_menu.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/jellyfin_api.dart' as jellyfin_api;
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/mix_export.dart';
import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as path_helper;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Saves [tracks] (a mix, in play order) to a new or existing playlist on the server.
Future<void> saveMixAsPlaylist(BuildContext context, List<BaseItemDto> tracks) =>
    showPlaylistActionsMenu(context: context, items: tracks);

/// Where on screen [context]'s widget is, for the share sheet to point at (needed on iPad).
Rect? shareOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  return box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
}

/// Shares [tracks] as an M3U playlist named [name], pointing at the songs' files as the server stores them. The
/// share sheet points at [origin], the button that asked.
Future<void> exportMixM3u(List<BaseItemDto> tracks, String name, {Rect? origin}) async {
  try {
    final paths = await _paths(tracks);
    final export = MixExport.m3u(name, tracks, pathOf: (track) => paths[track.id.raw]);
    if (export.skipped == tracks.length) {
      GlobalSnackbar.message((context) => context.l10n.exportMixNoPaths);
      return;
    }
    if (Platform.isLinux) {
      // Sharing files isn't available on Linux, so it's saved where the listener chooses instead.
      final path = await FilePicker.saveFile(
        fileName: MixExport.fileName(name),
        initialDirectory: (await getApplicationDocumentsDirectory()).path + path_helper.separator,
        bytes: utf8.encode(export.text),
      );
      if (path == null) return;
      await File(path).writeAsString(export.text);
    } else {
      await _share(export.text, name, origin);
    }
    if (export.skipped > 0) {
      GlobalSnackbar.message((context) => context.l10n.exportMixSkipped(export.skipped));
    }
  } catch (e) {
    GlobalSnackbar.error(e);
  }
}

/// Shares the playlist [text] as a file named after [name], the share sheet pointing at [origin].
Future<void> _share(String text, String name, Rect? origin) async {
  final file = File(path_helper.join((await getTemporaryDirectory()).path, MixExport.fileName(name)));
  await file.writeAsString(text);
  // Left in the temporary folder: the app it's shared with may still be reading it after the share sheet closes.
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: "audio/x-mpegurl")],
      sharePositionOrigin: origin,
    ),
  );
}

/// The file paths of [tracks] by id, which queue items don't carry, asked for in batches. None offline.
Future<Map<String, String>> _paths(List<BaseItemDto> tracks) async {
  final paths = <String, String>{};
  if (FinampSettingsHelper.finampSettings.isOffline) return paths;
  const batch = 200;
  final api = GetIt.instance<JellyfinApiHelper>();
  for (var start = 0; start < tracks.length; start += batch) {
    final fetched =
        await api.getItems(
          itemIds: [for (final track in tracks.skip(start).take(batch)) track.id],
          fields: "${jellyfin_api.defaultFields},Path",
        ) ??
        [];
    for (final track in fetched) {
      if (track.path != null) paths[track.id.raw] = track.path!;
    }
  }
  return paths;
}
