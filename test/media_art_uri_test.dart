import 'package:finamp/services/media_art_uri.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android artwork retains server authentication, dimensions and escaped query values', () {
    final original = Uri.parse(
      'https://music.test:8920/jellyfin/Items/id/Images/Primary?api_key=test%2Bkey&maxWidth=200',
    );
    final artwork = androidMediaArtworkUri(original, 'com.baslawson.finampplus');
    expect(artwork.authority, 'com.baslawson.finampplus');
    expect(artwork.path, original.path);
    expect(artwork.fragment, original.origin);
    expect(artwork.queryParameters, original.queryParameters);
    expect(Uri.parse(artwork.fragment).replace(path: artwork.path, query: artwork.query), original);
  });
  test('local artwork paths retain spaces without a network origin', () {
    final original = Uri.file('/data/user/0/com.baslawson.finampplus/files/images/Cover art.png');
    final artwork = androidMediaArtworkUri(original, 'com.baslawson.finampplus');
    expect(artwork.path, original.path);
    expect(artwork.hasFragment, isFalse);
    expect(artwork.hasQuery, isFalse);
  });
}
