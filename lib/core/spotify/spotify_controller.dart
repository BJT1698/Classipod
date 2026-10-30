import 'dart:async';

import 'package:classipod/core/constants/constants.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/spotify/spotify_auth.dart';
import 'package:classipod/core/spotify/spotify_client.dart';
import 'package:classipod/core/spotify/spotify_repository.dart';
import 'package:classipod/features/music/playlist/models/playlist_model.dart';
import 'package:classipod/features/music/playlist/providers/playlists_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

final spotifyAuthProvider = Provider<SpotifyAuth>((_) => SpotifyAuth());
final spotifyClientProvider = Provider<SpotifyClient>(
  (ref) => SpotifyClient(ref.read(spotifyAuthProvider)),
);
final spotifyRepositoryProvider = FutureProvider<SpotifyRepository>(
  (_) async => SpotifyRepository(await Hive.openBox<dynamic>('spotify-v1')),
);

class SpotifyState {
  final List<MusicMetadata> songs;
  final List<SpotifyPlaylist> playlists;
  final bool signedIn;
  final bool scanning;
  final int indexedSongs;
  final String? error;
  const SpotifyState({
    this.songs = const [],
    this.playlists = const [],
    this.signedIn = false,
    this.scanning = false,
    this.indexedSongs = 0,
    this.error,
  });

  SpotifyState copyWith({
    List<MusicMetadata>? songs,
    List<SpotifyPlaylist>? playlists,
    bool? signedIn,
    bool? scanning,
    int? indexedSongs,
    String? error,
  }) => SpotifyState(
    songs: songs ?? this.songs,
    playlists: playlists ?? this.playlists,
    signedIn: signedIn ?? this.signedIn,
    scanning: scanning ?? this.scanning,
    indexedSongs: indexedSongs ?? this.indexedSongs,
    error: error,
  );
}

final spotifyControllerProvider =
    AsyncNotifierProvider<SpotifyController, SpotifyState>(
      SpotifyController.new,
    );

class SpotifyController extends AsyncNotifier<SpotifyState> {
  int _generation = 0;

  @override
  Future<SpotifyState> build() async {
    ref.onDispose(() => _generation++);
    final auth = ref.read(spotifyAuthProvider);
    final repository = await ref.read(spotifyRepositoryProvider.future);
    try {
      await auth.load();
    } catch (_) {}
    final cached = repository.cached();
    if (auth.signedIn && cached == null) {
      unawaited(
        Future<void>(() async {
          if (ref.mounted) await refresh();
        }),
      );
    }
    return SpotifyState(
      songs: cached?.songs ?? const [],
      playlists: cached?.playlists ?? const [],
      signedIn: auth.signedIn,
    );
  }

  SpotifyState get _current => state.value ?? const SpotifyState();

  Future<void> signIn() async {
    final auth = ref.read(spotifyAuthProvider);
    if (!auth.configured) throw const SpotifyException('client_id');
    await auth.signIn();
    state = AsyncData(_current.copyWith(signedIn: true));
    unawaited(refresh());
  }

  Future<void> signOut() async {
    _generation++;
    final repository = await ref.read(spotifyRepositoryProvider.future);
    repository.cancel();
    await ref.read(spotifyAuthProvider).signOut();
    await _syncPlaylists(repository, const SpotifyLibrary([], []));
    await repository.box.clear();
    if (ref.mounted) ref.read(playlistsProvider.notifier).refreshProvider();
    state = const AsyncData(SpotifyState());
  }

  Future<void> refresh() async {
    final old = _current;
    if (!old.signedIn) return;
    final generation = ++_generation;
    final repository = await ref.read(spotifyRepositoryProvider.future);
    if (generation != _generation) return;
    state = AsyncData(old.copyWith(scanning: true, indexedSongs: 0));
    try {
      final library = await repository.scan(
        ref.read(spotifyClientProvider),
        progress: (count) {
          if (generation == _generation && ref.mounted) {
            state = AsyncData(
              old.copyWith(scanning: true, indexedSongs: count),
            );
          }
        },
      );
      if (generation != _generation || !ref.mounted) return;
      await _syncPlaylists(repository, library);
      if (!ref.mounted) return;
      ref.read(playlistsProvider.notifier).refreshProvider();
      state = AsyncData(
        SpotifyState(
          songs: library.songs,
          playlists: library.playlists,
          signedIn: true,
        ),
      );
    } catch (error) {
      if (generation != _generation || !ref.mounted) return;
      final reason = error is SpotifyException ? error.reason : 'response';
      state = AsyncData(
        old.copyWith(signedIn: reason != 'auth' && old.signedIn, error: reason),
      );
    }
  }
}

/// Mirrors Spotify playlists into the playlist box so the existing
/// Playlists screens show them; the mapping keeps their keys stable.
Future<void> _syncPlaylists(
  SpotifyRepository repository,
  SpotifyLibrary library,
) async {
  if (!Hive.isBoxOpen(Constants.playlistBoxName)) return;
  final box = Hive.box<PlaylistModel>(Constants.playlistBoxName);
  final keys = Map<String, int>.from(
    repository.box.get('playlistKeys') as Map? ?? const {},
  );
  final songs = {for (final song in library.songs) song.songId: song};
  final synced = <String, int>{};
  for (final playlist in library.playlists) {
    final model = PlaylistModel(
      name: playlist.name,
      songs: [
        for (final id in playlist.songIds)
          if (songs[id] != null) songs[id]!,
      ],
    );
    final key = keys[playlist.id];
    if (key != null && box.containsKey(key)) {
      await box.put(key, model);
      synced[playlist.id] = key;
    } else {
      synced[playlist.id] = await box.add(model);
    }
  }
  await box.deleteAll(
    keys.entries
        .where((entry) => !synced.containsKey(entry.key))
        .map((entry) => entry.value),
  );
  await repository.box.put('playlistKeys', synced);
}

String spotifyErrorMessage(String reason) => switch (reason) {
  'client_id' =>
    'Spotify Client ID missing. Build with '
        '--dart-define=SPOTIFY_CLIENT_ID=<your id>.',
  'auth' => 'Spotify session expired. Sign in again from Settings.',
  'no_device' =>
    'No Spotify device found. Open the Spotify app on this phone '
        'and try again.',
  'premium' => 'Controlling playback requires Spotify Premium.',
  'forbidden' =>
    'Spotify refused the request. Check that your account is added '
        'to the app in the Spotify Developer Dashboard.',
  'rate_limit' => 'Too many requests to Spotify. Try again in a minute.',
  'network' => 'Cannot reach Spotify. Check your connection.',
  _ => 'Spotify request failed ($reason).',
};
