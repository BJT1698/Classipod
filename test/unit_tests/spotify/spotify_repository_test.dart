import 'dart:convert';
import 'dart:io';

import 'package:classipod/core/spotify/spotify_auth.dart';
import 'package:classipod/core/spotify/spotify_client.dart';
import 'package:classipod/core/spotify/spotify_repository.dart';
import 'package:classipod/hive/hive_registrar.g.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const base = 'https://api.spotify.com/v1';

Map<String, dynamic> album(String id, {List<Map<String, dynamic>>? tracks}) => {
  'id': id,
  'name': 'Album $id',
  'total_tracks': 12,
  'release_date': '1997-05-21',
  'artists': [
    {'name': 'Band'},
    {'name': 'Guest'},
  ],
  'images': [
    {'url': 'https://i/$id/300', 'width': 300, 'height': 300},
    {'url': 'https://i/$id/640', 'width': 640, 'height': 640},
    {'url': 'https://i/$id/64', 'width': 64, 'height': 64},
  ],
  'tracks': ?tracks == null ? null : {'items': tracks, 'next': null},
};

Map<String, dynamic> track(String id, {bool withAlbum = true}) => {
  'id': id,
  'uri': 'spotify:track:$id',
  'type': 'track',
  'name': 'Song $id',
  'artists': [
    {'name': 'Singer'},
  ],
  'track_number': 3,
  'disc_number': 1,
  'duration_ms': 201000,
  if (withAlbum) 'album': album('al$id'),
};

Map<String, dynamic> page(List<Object?> items, [String? next]) => {
  'items': items,
  'next': next,
};

int inAnHour() =>
    DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseTrack', () {
    test('maps Spotify track to MusicMetadata', () {
      final song = SpotifyRepository.parseTrack(track('t1'));
      expect(song.songId, 'spotify:track:t1');
      expect(song.remoteSongId, 't1');
      expect(song.remoteAlbumId, 'alt1');
      expect(song.serverId, isNull);
      expect(song.isSubsonic, isFalse);
      expect(song.isOnDevice, isFalse);
      expect(song.trackName, 'Song t1');
      expect(song.trackArtistNames, ['Singer']);
      expect(song.albumName, 'Album alt1');
      expect(song.albumArtistName, 'Band; Guest');
      expect(song.albumArtistNames, ['Band', 'Guest']);
      expect(song.trackNumber, 3);
      expect(song.discNumber, 1);
      expect(song.albumLength, 12);
      expect(song.year, 1997);
      expect(song.genres, isEmpty);
      expect(song.trackDuration, 201000);
      expect(song.thumbnailPath, 'https://i/alt1/640');
      expect(song.mimeType, isNull);
    });

    test('uses explicit album and tolerates missing images', () {
      final song = SpotifyRepository.parseTrack(
        track('t2', withAlbum: false),
        album: {...album('x'), 'images': [], 'release_date': '2001'},
      );
      expect(song.remoteAlbumId, 'x');
      expect(song.year, 2001);
      expect(song.thumbnailPath, isNull);
      expect(
        () => SpotifyRepository.parseTrack({'id': 'x'}),
        throwsA(isA<SpotifyException>()),
      );
    });
  });

  group('scan', () {
    late Directory directory;
    late SpotifyRepository repository;
    late SpotifyClient client;
    final requested = <String>[];

    setUp(() async {
      requested.clear();
      directory = await Directory.systemTemp.createTemp('spotify-test-');
      Hive.init(directory.path);
      if (!Hive.isAdapterRegistered(2)) Hive.registerAdapters();
      repository = SpotifyRepository(await Hive.openBox<dynamic>('spotify'));
      FlutterSecureStorage.setMockInitialValues({
        'spotify:access': 'a',
        'spotify:refresh': 'r',
        'spotify:expiry': '${inAnHour()}',
      });
      final auth = SpotifyAuth(clientIdOverride: 'c');
      await auth.load();
      client = SpotifyClient(
        auth,
        httpClient: MockClient((request) async {
          final url = request.url.toString().replaceFirst(base, '');
          requested.add(url);
          final Object body = switch (url) {
            '/me/tracks?limit=50' => page([
              {'track': track('t1')},
            ], '$base/me/tracks?offset=1'),
            '/me/tracks?offset=1' => page([
              {'track': track('t2')},
              {'track': null},
            ]),
            '/me/albums?limit=50' => page([
              {
                'album': {
                  ...album('A', tracks: [track('t1', withAlbum: false)]),
                  'tracks': {
                    'items': [track('t1', withAlbum: false)],
                    'next': '$base/albums/A/tracks?offset=1',
                  },
                },
              },
            ]),
            '/albums/A/tracks?offset=1' => page([
              track('t3', withAlbum: false),
            ]),
            '/me' => {'id': 'me'},
            '/me/playlists?limit=50' => page([
              {
                'id': 'mine',
                'name': 'Mine',
                'owner': {'id': 'me'},
                'images': [
                  {'url': 'https://p/mine', 'width': null},
                ],
              },
              {
                'id': 'other',
                'name': 'Other',
                'owner': {'id': 'spotify'},
              },
              {
                'id': 'collab',
                'name': 'Collab',
                'collaborative': true,
                'owner': {'id': 'friend'},
              },
              {
                'id': 'empty',
                'name': 'Empty',
                'owner': {'id': 'me'},
              },
            ]),
            '/playlists/mine/items?limit=50' => page([
              {'item': track('t4')},
              {'track': track('t2')},
              {
                'item': {...track('local'), 'is_local': true},
              },
              {
                'item': {
                  'id': 'ep',
                  'uri': 'spotify:episode:ep',
                  'type': 'episode',
                },
              },
              {'item': null},
              {'item': track('t4')},
            ]),
            '/playlists/collab/items?limit=50' => http.Response(
              jsonEncode({
                'error': {'status': 403, 'message': 'Forbidden'},
              }),
              403,
            ),
            '/playlists/empty/items?limit=50' => page([]),
            _ => http.Response('', 500),
          };
          return body is http.Response
              ? body
              : http.Response(jsonEncode(body), 200);
        }),
      );
    });

    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test('unions sources, dedupes, skips unreadable playlists', () async {
      final counts = <int>[];
      final library = await repository.scan(client, progress: counts.add);
      expect(library.songs.map((s) => s.remoteSongId), [
        't1',
        't2',
        't3',
        't4',
      ]);
      expect(library.songs.first.remoteAlbumId, 'alt1');
      expect(library.songs[2].remoteAlbumId, 'A');
      expect(counts, [1, 2, 3, 4]);
      expect(requested, isNot(contains('/playlists/other/items?limit=50')));
      expect(library.playlists.map((p) => p.id), ['mine', 'empty']);
      final mine = library.playlists.first;
      expect(mine.name, 'Mine');
      expect(mine.imageUrl, 'https://p/mine');
      expect(mine.songIds, [
        'spotify:track:t4',
        'spotify:track:t2',
        'spotify:track:t4',
      ]);

      final cached = repository.cached()!;
      expect(
        cached.songs.map((s) => s.songId),
        library.songs.map((s) => s.songId),
      );
      expect(cached.songs.first.serverId, isNull);
      expect(cached.playlists.first.songIds, mine.songIds);
      expect(cached.playlists.last.songIds, isEmpty);
    });

    test('cancel aborts scan without persisting', () async {
      expect(repository.cached(), isNull);
      final scan = repository.scan(
        client,
        progress: (_) => repository.cancel(),
      );
      await expectLater(
        scan,
        throwsA(
          isA<SpotifyException>().having((e) => e.reason, 'r', 'cancelled'),
        ),
      );
      expect(repository.cached(), isNull);
    });
  });
}
