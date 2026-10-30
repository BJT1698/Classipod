import 'dart:async';

import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/spotify/spotify_client.dart';
import 'package:hive_ce/hive.dart';

class SpotifyPlaylist {
  final String id, name;
  final String? imageUrl;
  final List<String> songIds;
  const SpotifyPlaylist({
    required this.id,
    required this.name,
    this.imageUrl,
    this.songIds = const [],
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'imageUrl': imageUrl,
    'songIds': songIds,
  };

  factory SpotifyPlaylist.fromMap(Map<dynamic, dynamic> map) => SpotifyPlaylist(
    id: map['id'] as String,
    name: map['name'] as String,
    imageUrl: map['imageUrl'] as String?,
    songIds: (map['songIds'] as List).cast<String>(),
  );
}

class SpotifyLibrary {
  final List<MusicMetadata> songs;
  final List<SpotifyPlaylist> playlists;
  const SpotifyLibrary(this.songs, this.playlists);
}

class SpotifyRepository {
  final Box<dynamic> box;
  int _generation = 0;
  SpotifyRepository(this.box);

  void cancel() => _generation++;

  SpotifyLibrary? cached() {
    final songs = box.get('songs');
    final playlists = box.get('playlists');
    if (songs is! List) return null;
    return SpotifyLibrary(songs.cast<MusicMetadata>(), [
      for (final playlist in playlists as List? ?? [])
        SpotifyPlaylist.fromMap(playlist as Map),
    ]);
  }

  Future<SpotifyLibrary> scan(
    SpotifyClient client, {
    void Function(int songs)? progress,
  }) async {
    final generation = ++_generation;
    void check() {
      if (generation != _generation) {
        throw const SpotifyException('cancelled');
      }
    }

    final songs = <String, MusicMetadata>{};
    String? add(Object? track, [Map<String, dynamic>? album]) {
      if (track is! Map<String, dynamic> ||
          track['is_local'] == true ||
          (track['type'] ?? 'track') != 'track' ||
          track['id'] is! String) {
        return null;
      }
      final song = parseTrack(track, album: album);
      final known = songs[song.remoteSongId];
      if (known != null) return known.songId;
      songs[song.remoteSongId!] = song;
      progress?.call(songs.length);
      return song.songId;
    }

    await for (final item in client.paged('/me/tracks')) {
      check();
      add(item['track']);
    }
    check();
    await for (final item in client.paged('/me/albums')) {
      check();
      final album = item['album'];
      if (album is! Map<String, dynamic>) continue;
      final tracks = album['tracks'];
      if (tracks is! Map) continue;
      for (final track in tracks['items'] as List? ?? []) {
        add(track, album);
      }
      final next = tracks['next'];
      if (next is String && next.isNotEmpty) {
        await for (final track in client.paged(next)) {
          check();
          add(track, album);
        }
      }
    }
    check();
    final user = (await client.get('/me'))['id'];
    check();
    final playlists = <SpotifyPlaylist>[];
    await for (final playlist in client.paged('/me/playlists')) {
      check();
      final id = playlist['id'];
      final owner = playlist['owner'];
      final owned = owner is Map && owner['id'] == user;
      if (id is! String || !(owned || playlist['collaborative'] == true)) {
        continue;
      }
      final songIds = <String>[];
      try {
        await for (final item in client.paged('/playlists/$id/items')) {
          check();
          final songId = add(item['item'] ?? item['track']);
          if (songId != null) songIds.add(songId);
        }
      } on SpotifyException catch (e) {
        if (e.reason != 'forbidden' && e.reason != 'not_found') rethrow;
        continue;
      }
      if (songIds.isEmpty && !owned) continue;
      playlists.add(
        SpotifyPlaylist(
          id: id,
          name: playlist['name']?.toString() ?? '',
          imageUrl: _image(playlist['images']),
          songIds: songIds,
        ),
      );
    }
    check();
    final result = songs.values.toList();
    await box.put('songs', result);
    await box.put('playlists', [for (final p in playlists) p.toMap()]);
    check();
    return SpotifyLibrary(result, playlists);
  }

  static String? _image(Object? images) {
    String? url;
    var best = 1 << 30;
    for (final image in images is List ? images : const []) {
      if (image is! Map || image['url'] is! String) continue;
      final width = image['width'];
      final distance = width is num ? (width - 640).abs().toInt() : 1 << 29;
      if (distance < best) {
        best = distance;
        url = image['url'] as String;
      }
    }
    return url;
  }

  static MusicMetadata parseTrack(
    Map<String, dynamic> track, {
    Map<String, dynamic>? album,
  }) {
    final id = track['id'];
    final uri = track['uri'];
    if (id is! String || id.isEmpty || uri is! String || uri.isEmpty) {
      throw const SpotifyException('response');
    }
    final data = album ?? track['album'];
    final info = data is Map ? data : const {};
    List<String> names(Object? artists) => [
      for (final artist in artists is List ? artists : const [])
        if (artist is Map && artist['name'] is String) artist['name'] as String,
    ];
    final albumArtists = names(info['artists']);
    final release = info['release_date']?.toString() ?? '';
    int? integer(Object? value) => value is num ? value.toInt() : null;
    return MusicMetadata(
      remoteSongId: id,
      remoteAlbumId: info['id']?.toString(),
      songId: uri,
      isOnDevice: false,
      trackName: track['name']?.toString(),
      trackArtistNames: names(track['artists']),
      albumName: info['name']?.toString(),
      albumArtistName: albumArtists.join('; '),
      albumArtistNames: albumArtists,
      trackNumber: integer(track['track_number']),
      discNumber: integer(track['disc_number']),
      albumLength: integer(info['total_tracks']),
      year: release.length < 4 ? null : int.tryParse(release.substring(0, 4)),
      trackDuration: integer(track['duration_ms']),
      thumbnailPath: _image(info['images']),
    );
  }
}
