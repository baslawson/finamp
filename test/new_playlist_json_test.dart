import 'package:finamp/models/jellyfin_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a new playlist leaves out its visibility unless it is set, which Jellyfin requires', () {
    final unset = NewPlaylist(name: 'Finamp+ Smart Downloads', userId: 'user', mediaType: 'Audio').toJson();
    expect(unset.containsKey('IsPublic'), isFalse);
    expect(unset['Name'], 'Finamp+ Smart Downloads');
    expect(NewPlaylist(name: 'Mine', isPublic: false).toJson()['IsPublic'], isFalse);
    expect(NewPlaylist(name: 'Shared', isPublic: true).toJson()['IsPublic'], isTrue);
  });
}
