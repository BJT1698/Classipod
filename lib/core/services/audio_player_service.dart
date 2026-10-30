import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:classipod/core/alerts/dialogs.dart';
import 'package:classipod/core/constants/keys.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/models/playback_shuffle_mode.dart';
import 'package:classipod/core/providers/filtered_audio_files_provider.dart';
import 'package:classipod/core/services/playback/playback_session.dart';
import 'package:classipod/core/services/playback/spotify_audio_handler.dart';
import 'package:classipod/core/spotify/spotify_controller.dart';
import 'package:classipod/features/music/album/models/album_model.dart';
import 'package:classipod/features/music/playlist/models/playlist_model.dart';
import 'package:classipod/features/now_playing/models/now_playing_model.dart';
import 'package:classipod/features/now_playing/provider/now_playing_details_provider.dart';
import 'package:classipod/features/settings/controller/settings_preferences_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:url_launcher/url_launcher.dart';

final libraryAudioHandlerProvider = Provider<SpotifyAudioHandler>((ref) {
  final handler = SpotifyAudioHandler(
    ref.read(spotifyClientProvider),
    openSpotify: () async {
      await launchUrl(
        Uri.parse('spotify:'),
        mode: LaunchMode.externalNonBrowserApplication,
      );
    },
  );
  handler.onError = (error) {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    unawaited(
      Dialogs.showInfoDialog(
        context: context,
        title: 'Spotify',
        content: spotifyErrorMessage(error.reason),
      ),
    );
  };
  final lifecycle = AppLifecycleListener(
    onResume: handler.resume,
    onHide: handler.suspend,
  );
  handler.resume();
  ref.onDispose(() {
    lifecycle.dispose();
    unawaited(handler.dispose());
  });
  return handler;
});

void _reconcileLibrary(Ref ref, SpotifyAudioHandler handler) {
  if (handler.restoringSession) return;
  final now = ref.read(nowPlayingDetailsProvider);
  final library = ref.read(filteredAudioFilesProvider).value;
  final songs = now.nowPlayingType == NowPlayingType.songs && library != null
      ? library.toList()
      : now.metadataList;
  if (listEquals(now.metadataList, songs)) return;
  ref.read(nowPlayingDetailsProvider.notifier).reconcileMetadata(songs);
  unawaited(handler.reconcileSongs(songs));
}

final audioPlayerServiceProvider =
    AsyncNotifierProvider<AudioPlayerServiceNotifier, void>(
      AudioPlayerServiceNotifier.new,
    );

class AudioPlayerServiceNotifier extends AsyncNotifier<void> {
  AudioPlayerServiceNotifier() : super();

  bool _sessionRestored = false;

  @override
  Future<void> build() async {
    final handler = ref.watch(libraryAudioHandlerProvider);
    ref.listen(filteredAudioFilesProvider, (previous, next) {
      if (next.hasValue && previous?.value != next.value) {
        _reconcileLibrary(ref, handler);
      }
    });
  }

  Future<void> restoreSession(List<MusicMetadata> library) async {
    final handler = ref.read(libraryAudioHandlerProvider);
    if (_sessionRestored) {
      _reconcileLibrary(ref, handler);
      return;
    }
    handler.restoringSession = true;
    try {
      PlaybackSessionStore? store;
      try {
        store = PlaybackSessionStore(
          await Hive.openBox<dynamic>('playback-session-v1'),
        );
      } catch (error) {
        debugPrint('Could not open playback session: ${error.runtimeType}');
      }
      final initialRepeatMode = handler.playbackState.value.repeatMode;
      final savedSession = store?.read();
      final session =
          savedSession != null &&
              library.any(
                (song) => song.identity == savedSession.ids[savedSession.index],
              )
          ? savedSession
          : null;
      if (savedSession != null && session == null) await store?.clear();
      final restored = session?.resolve(library);
      final songs = restored?.songs ?? library;
      ref
          .read(nowPlayingDetailsProvider.notifier)
          .setNewMetadataList(
            nowPlayingType: session?.type ?? NowPlayingType.songs,
            newMetadataList: songs,
          );
      await handler.restoreSongs(
        songs,
        index: restored?.index ?? 0,
        position: Duration.zero,
        resetOnFailure: session != null,
      );
      if (session != null) {
        await handler.setShuffleMode(session.shuffle.audioServiceMode);
        await handler.setRepeatMode(switch (session.loop) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        });
      }
      handler.onRestoreFailure = () {
        handler.onCheckpoint = null;
        unawaited(_resetRestoredSession(handler, store, initialRepeatMode));
      };
      ref.onDispose(() => handler.onRestoreFailure = null);
      if (store != null) {
        store.attach(
          handler,
          () => ref.read(nowPlayingDetailsProvider).nowPlayingType,
        );
        ref.onDispose(() {
          handler.onCheckpoint = null;
          unawaited(store!.dispose());
        });
      }
      _sessionRestored = true;
    } finally {
      handler.restoringSession = false;
    }
  }

  Future<void> _resetRestoredSession(
    SpotifyAudioHandler handler,
    PlaybackSessionStore? store,
    AudioServiceRepeatMode initialRepeatMode,
  ) async {
    await store?.clear();
    if (!ref.mounted) return;
    final library =
        ref.read(filteredAudioFilesProvider).value?.toList() ??
        <MusicMetadata>[];
    ref
        .read(nowPlayingDetailsProvider.notifier)
        .setNewMetadataList(
          nowPlayingType: NowPlayingType.songs,
          newMetadataList: library,
        );
    try {
      await handler.setSongs(library, preload: false);
      await handler.setShuffleMode(AudioServiceShuffleMode.none);
      await handler.setRepeatMode(initialRepeatMode);
    } catch (error) {
      debugPrint('Could not reset playback: ${error.runtimeType}');
    } finally {
      if (ref.mounted) {
        store?.attach(
          handler,
          () => ref.read(nowPlayingDetailsProvider).nowPlayingType,
        );
      }
    }
  }

  Future<void> play() async {
    state = await AsyncValue.guard(_play);
  }

  Future<void> _play() async {
    final handler = ref.read(libraryAudioHandlerProvider);
    if (handler.playing && handler.playbackState.value.errorCode == null) {
      return;
    }

    await handler.play();
  }

  Future<void> pause() async {
    await ref.read(libraryAudioHandlerProvider).pause();
  }

  Future<void> stop() async {
    await ref.read(libraryAudioHandlerProvider).stop();
  }

  Future<void> toggleShuffleMode() async {
    await setShuffleMode(
      ref.read(libraryAudioHandlerProvider).logicalQueue.shuffleMode.next,
    );
  }

  Future<void> setShuffleMode(PlaybackShuffleMode mode) async {
    state = await AsyncValue.guard(() async {
      final handler = ref.read(libraryAudioHandlerProvider);
      await handler.setShuffleMode(mode.audioServiceMode);
    });
  }

  Future<void> shuffleAllSongs() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      //If Album or Playlist is being played then Switch to original List of Songs
      if (ref.read(nowPlayingDetailsProvider).nowPlayingType !=
              NowPlayingType.songs ||
          ref.read(nowPlayingDetailsProvider).metadataList.isEmpty) {
        await setAudioSource(
          musicMetadataList: ref.read(filteredAudioFilesProvider).requireValue,
        );
      }

      await setShuffleMode(PlaybackShuffleMode.songs);
      await nextSong();
      Future.delayed(const Duration(milliseconds: 100), play);

      await ref
          .read(settingsPreferencesControllerProvider.notifier)
          .setInitialRepeatMode();
    });
  }

  Future<void> setLoopMode(LoopMode loopMode) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await ref.read(libraryAudioHandlerProvider).setRepeatMode(
        switch (loopMode) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
      );
    });
  }

  Future<void> setAudioSource({
    NowPlayingType nowPlayingType = NowPlayingType.songs,
    bool preload = true,
    required List<MusicMetadata> musicMetadataList,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      ref
          .read(nowPlayingDetailsProvider.notifier)
          .setNewMetadataList(
            nowPlayingType: nowPlayingType,
            newMetadataList: musicMetadataList,
          );

      await ref
          .read(libraryAudioHandlerProvider)
          .setSongs(musicMetadataList, preload: preload);
    });
  }

  Future<void> nextSong() async {
    state = await AsyncValue.guard(
      () => ref.read(libraryAudioHandlerProvider).skipToNext(),
    );
  }

  Future<void> seekBackwards() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await ref.read(libraryAudioHandlerProvider).skipToPrevious();
    });
  }

  Future<void> playAlbum({
    required AlbumModel albumDetail,
    required int songIndex,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      // If Album has no songs or the songIndex is out of bounds
      if (albumDetail.albumSongs.isEmpty ||
          songIndex >= albumDetail.albumSongs.length) {
        return;
      }
      final nowPlayingDetails = ref.read(nowPlayingDetailsProvider);

      // If the album is already playing
      if (nowPlayingDetails.nowPlayingType == NowPlayingType.album &&
          nowPlayingDetails.currentMetadata?.getAlbumDetail == albumDetail) {
        await playSongAtIndex(songIndex);
        return;
      } else {
        await setAudioSource(
          preload: false,
          nowPlayingType: NowPlayingType.album,
          musicMetadataList: albumDetail.albumSongs,
        );
        await playSongAtIndex(songIndex);
        Future.delayed(const Duration(milliseconds: 100), play);
      }
    });
  }

  Future<void> playPlaylist({
    required PlaylistModel playlistDetail,
    required int songIndex,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      // If Playlist has no songs or the songIndex is out of bounds
      if (playlistDetail.songs.isEmpty ||
          songIndex >= playlistDetail.songs.length) {
        return;
      }
      final nowPlayingDetails = ref.read(nowPlayingDetailsProvider);

      // If the playlist is already playing
      if (nowPlayingDetails.nowPlayingType == NowPlayingType.playlist &&
          listEquals(nowPlayingDetails.metadataList, playlistDetail.songs)) {
        await playSongAtIndex(songIndex);
        return;
      } else {
        await setAudioSource(
          preload: false,
          nowPlayingType: NowPlayingType.playlist,
          musicMetadataList: playlistDetail.songs,
        );
        await playSongAtIndex(songIndex);
        Future.delayed(const Duration(milliseconds: 100), play);
      }
    });
  }

  Future<void> playSongAtIndex(int index) async {
    state = await AsyncValue.guard(() async {
      if (ref.read(nowPlayingDetailsProvider).currentIndex == index) {
        await _play();
      } else {
        await ref.read(libraryAudioHandlerProvider).select(index);
      }
    });
  }

  Future<void> playSongFromLibrary(String songId) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      //If Album or Playlist is being played then Switch to original List of Songs
      if (ref.read(nowPlayingDetailsProvider).nowPlayingType !=
              NowPlayingType.songs ||
          ref.read(nowPlayingDetailsProvider).metadataList.isEmpty) {
        await setAudioSource(
          musicMetadataList: ref.read(filteredAudioFilesProvider).requireValue,
        );
      }

      //In case the same song is already playing
      if (songId ==
          ref.read(nowPlayingDetailsProvider).currentMetadata?.identity) {
        await _play();
        return;
      }

      final int index = ref
          .read(nowPlayingDetailsProvider)
          .metadataList
          .indexWhere((element) => element.identity == songId);
      if (index < 0) return;
      await ref.read(libraryAudioHandlerProvider).select(index);
    });
  }

  Future<void> togglePlayback() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final handler = ref.read(libraryAudioHandlerProvider);
      if (handler.playing) {
        await pause();
      } else {
        await _play();
      }
    });
  }

  Future<void> seekForward() => seekToDuration(
    ref.read(libraryAudioHandlerProvider).displayPosition.inSeconds + 1,
  );

  Future<void> seekBackward() => seekToDuration(
    ref.read(libraryAudioHandlerProvider).displayPosition.inSeconds - 1,
  );

  Future<void> seekToDuration(int targetDurationInSeconds) async {
    state = await AsyncValue.guard(() async {
      final duration =
          ref
              .read(nowPlayingDetailsProvider)
              .currentMetadata
              ?.getTrackDuration ??
          0;
      final target = duration > 0
          ? targetDurationInSeconds.clamp(0, duration ~/ 1000)
          : targetDurationInSeconds.clamp(0, 1 << 31);
      await ref
          .read(libraryAudioHandlerProvider)
          .seek(Duration(seconds: target));
    });
  }
}
