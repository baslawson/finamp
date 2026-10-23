/// Reload a selected song without letting a late failure restore an obsolete queue.
/// [ownsLoad] must follow the generation started by [load] and [restore].
Future<void> reloadKaraokeAudio({
  required Future<void> Function() pause,
  required bool Function() stillSelected,
  required Future<void> Function() load,
  required bool Function() ownsLoad,
  required Future<void> Function() restore,
  void Function()? resume,
}) async {
  await pause();
  if (!stillSelected()) return;
  try {
    await load();
  } catch (_) {
    if (ownsLoad()) {
      await restore();
      if (ownsLoad()) resume?.call();
    }
    rethrow;
  }
  if (ownsLoad()) resume?.call();
}
