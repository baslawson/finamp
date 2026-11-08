import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/downloads_service_backend.dart';
import 'package:flutter_test/flutter_test.dart';

BaseItemDto _playlist(String? etag, {int childCount = 2}) => BaseItemDto(
  id: const BaseItemId('0123456789abcdef0123456789abcdef'),
  name: 'Road trip',
  type: 'Playlist',
  etag: etag,
  childCount: childCount,
);

DownloadItem _stored(BaseItemDto item) =>
    DownloadStub.fromItem(type: DownloadItemType.collection, item: item).asItem(null);

void main() {
  group("an unchanged playlist", () {
    bool unchanged({
      String? stored = "a",
      String? fresh = "a",
      int? server = 3,
      int linked = 3,
      bool tracksStored = true,
      bool sameDetails = true,
      DownloadItemState state = DownloadItemState.complete,
      bool childFailed = false,
    }) => DownloadsSyncService.playlistUnchanged(
      storedEtag: stored,
      freshEtag: fresh,
      serverTracks: server,
      linkedTracks: linked,
      tracksStored: tracksStored,
      sameDetails: sameDetails,
      state: state,
      childFailed: childFailed,
    );

    test("has the same etag and the same number of tracks", () => expect(unchanged(), isTrue));

    test("a new etag means it changed", () => expect(unchanged(fresh: "b"), isFalse));

    test("no stored etag can't count as unchanged", () {
      expect(unchanged(stored: null), isFalse);
      expect(unchanged(stored: null, fresh: null), isFalse);
    });

    test("tracks not stored yet mean it still needs loading, even with the same etag", () {
      expect(unchanged(linked: 0), isFalse);
    });

    test("a different track count means it changed, even with the same etag", () {
      expect(unchanged(server: 2), isFalse);
    });

    test("a server that gives no track count can't count as unchanged", () {
      expect(unchanged(server: null), isFalse);
    });

    test("an empty playlist that's been synced is unchanged", () {
      expect(unchanged(server: 0, linked: 0), isTrue);
    });

    test("an empty playlist that's never been synced still needs setting up", () {
      expect(unchanged(server: 0, linked: 0, tracksStored: false), isFalse);
    });

    test("a rename or new cover is noticed even with the same etag", () {
      expect(unchanged(sameDetails: false), isFalse);
    });

    test("a failed sync gets another try, which is what clears it", () {
      expect(unchanged(state: DownloadItemState.syncFailed), isFalse);
    });

    test("a playlist that's only not downloaded yet can still be left out", () {
      expect(unchanged(state: DownloadItemState.notDownloaded), isTrue);
    });

    test("a failed cover or song gets another try", () {
      expect(unchanged(childFailed: true), isFalse);
    });
  });

  group("keeping a playlist's etag", () {
    test("a new etag alone is stored", () {
      final updated = _stored(_playlist("old")).copyWith(item: _playlist("new"), forceCopy: false);
      expect(updated?.baseItem?.etag, "new");
    });

    test("the same etag changes nothing", () {
      expect(_stored(_playlist("same")).copyWith(item: _playlist("same"), forceCopy: false), isNull);
    });

    test("other kinds of item don't get rewritten for a new etag", () {
      BaseItemDto album(String etag) => BaseItemDto(
        id: const BaseItemId('0123456789abcdef0123456789abcdef'),
        name: 'Axis',
        type: 'MusicAlbum',
        etag: etag,
        childCount: 2,
      );
      expect(_stored(album("old")).copyWith(item: album("new"), forceCopy: false), isNull);
    });

    test("no new item leaves it alone", () {
      expect(_stored(_playlist("same")).copyWith(forceCopy: false), isNull);
    });
  });

  group("an automatic resync leaves out unchanged playlists", () {
    bool mayLeaveOut({bool full = false, bool waiting = false, bool userSync = false}) =>
        DownloadsService.mayLeaveOutPlaylists(fullCheck: full, syncsWaiting: waiting, userSyncStarted: userSync);

    test("when nothing else is going on", () => expect(mayLeaveOut(), isTrue));

    test("but not on the weekly full check", () => expect(mayLeaveOut(full: true), isFalse));

    test("but not with other sync work running or left over", () => expect(mayLeaveOut(waiting: true), isFalse));

    test("but not when the user started a sync meanwhile", () => expect(mayLeaveOut(userSync: true), isFalse));
  });

  group("the weekly full check of every playlist", () {
    final now = DateTime(2026, 11, 9);

    test("is due the first time", () => expect(DownloadsService.fullPlaylistCheckDue(null, now), isTrue));

    test("isn't due within the week", () {
      expect(DownloadsService.fullPlaylistCheckDue(now.subtract(const Duration(days: 6)), now), isFalse);
    });

    test("is due after a week", () {
      expect(DownloadsService.fullPlaylistCheckDue(now.subtract(const Duration(days: 7)), now), isTrue);
    });

    test("is due when the clock was set back", () {
      expect(DownloadsService.fullPlaylistCheckDue(now.add(const Duration(days: 1)), now), isTrue);
    });
  });
}
