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
    bool mayLeaveOut({bool full = false, bool trusted = true, bool waiting = false, bool userSync = false}) =>
        DownloadsService.mayLeaveOutPlaylists(
          fullCheck: full,
          etagTrusted: trusted,
          syncsWaiting: waiting,
          userSyncStarted: userSync,
        );

    test("when nothing else is going on", () => expect(mayLeaveOut(), isTrue));

    test("but not on a Jellyfin version where etags aren't known to be right", () {
      expect(mayLeaveOut(trusted: false), isFalse);
    });

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

  group("checking that playlist etags can be relied on", () {
    ({bool full, bool trusted, bool verify}) plan({String? version = "12.4.0", String? last, bool fullDue = false}) =>
        DownloadsService.etagPlan(serverVersion: version, lastCheck: last, fullDue: fullDue);

    test("the first resync on a version checks everything and confirms the etags", () {
      expect(plan(last: null), (full: true, trusted: false, verify: true));
    });

    test("a Jellyfin upgrade checks everything again, even with etags confirmed on the old version", () {
      expect(plan(last: "ok|12.3.0"), (full: true, trusted: false, verify: true));
    });

    test("confirmed etags let playlists be left out between full checks", () {
      expect(plan(last: "ok|12.4.0"), (full: false, trusted: true, verify: false));
    });

    test("each weekly full check confirms them again", () {
      expect(plan(last: "ok|12.4.0", fullDue: true), (full: true, trusted: true, verify: true));
    });

    test("etags found wrong keep playlists in until Jellyfin's version changes", () {
      expect(plan(last: "off|12.4.0"), (full: false, trusted: false, verify: false));
      expect(plan(last: "off|12.4.0", fullDue: true), (full: true, trusted: false, verify: false));
      expect(plan(last: "off|12.3.0"), (full: true, trusted: false, verify: true));
    });

    test("an unknown version checks everything but learns nothing", () {
      expect(plan(version: null, last: "ok|12.4.0"), (full: true, trusted: false, verify: false));
    });

    test("a stored value that can't be read counts as never checked", () {
      expect(plan(last: "garbled"), (full: true, trusted: false, verify: true));
    });

    String? result({int checked = 240, int missed = 0, bool finished = true}) =>
        DownloadsService.etagCheckResult(version: "12.4.0", checked: checked, missed: missed, finished: finished);

    test("a finished check where every playlist matched confirms the version", () {
      expect(result(), "ok|12.4.0");
    });

    test("one playlist that changed without a new etag turns leaving out off", () {
      expect(result(missed: 1), "off|12.4.0");
    });

    test("a miss counts even if the check was cut short", () {
      expect(result(missed: 1, finished: false), "off|12.4.0");
    });

    test("a check cut short confirms nothing, so the next resync checks everything again", () {
      expect(result(finished: false), isNull);
    });

    test("a check that compared no playlists confirms nothing either", () {
      expect(result(checked: 0), isNull);
    });

    test("the same tracks in the same order match", () {
      expect(DownloadsSyncService.sameTracks([1, 2, 3], [1, 2, 3]), isTrue);
      expect(DownloadsSyncService.sameTracks([], []), isTrue);
    });

    test("an added, removed, swapped or moved track doesn't", () {
      expect(DownloadsSyncService.sameTracks([1, 2], [1, 2, 3]), isFalse);
      expect(DownloadsSyncService.sameTracks([1, 2, 3], [1, 3]), isFalse);
      expect(DownloadsSyncService.sameTracks([1, 2, 3], [1, 2, 4]), isFalse);
      expect(DownloadsSyncService.sameTracks([1, 2, 3], [3, 1, 2]), isFalse);
    });
  });
}
