import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/models/playback_shuffle_mode.dart';
import 'package:classipod/core/services/playback/logical_queue.dart';
import 'package:classipod/core/spotify/spotify_client.dart';
import 'package:classipod/core/utils/album_order.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

/// Drives playback on a Spotify Connect device through the Web API.
///
/// ClassiPod keeps owning the queue (order, shuffle, repeat): every time
/// playback starts, the next [windowSize] tracks of the logical queue are
/// handed to Spotify, and polling maps the device's current track back onto
/// the queue.
class SpotifyAudioHandler extends BaseAudioHandler {
  final SpotifyClient client;
  final Future<void> Function()? openSpotify;
  final Duration pollInterval;
  final Duration tickInterval;

  /// How long polled state is ignored after a command, so a stale response
  /// cannot undo it.
  final Duration quietPeriod;
  final int windowSize;
  bool restoringSession = false;
  VoidCallback? onCheckpoint;
  VoidCallback? onRestoreFailure;
  void Function(SpotifyException error)? onError;

  final LogicalQueue logicalQueue = LogicalQueue();
  final StreamController<int?> _indices = StreamController.broadcast();
  final StreamController<Duration> _positions = StreamController.broadcast();
  final StreamController<bool> _playingChanges = StreamController.broadcast();
  final StreamController<Duration?> _durations = StreamController.broadcast();
  final StreamController<double> _volumes = StreamController.broadcast();
  List<MusicMetadata> _songs = [];
  List<int> _window = [];
  int _windowPosition = 0;
  String? _deviceId;
  String? _remoteRepeat;
  bool? _remoteShuffle;
  bool _playing = false;
  bool _wantPlayback = false;
  bool _loading = false;
  bool _active = false;
  bool _disposed = false;
  bool _polling = false;
  Duration _position = Duration.zero;
  DateTime _positionAt = DateTime.now();
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);
  double _volume = 1;
  int _version = 0;
  String? _error;
  Timer? _poll;
  Timer? _tick;
  Future<void> _pending = Future.value();

  SpotifyAudioHandler(
    this.client, {
    this.openSpotify,
    this.pollInterval = const Duration(seconds: 2),
    this.tickInterval = const Duration(milliseconds: 500),
    this.quietPeriod = const Duration(milliseconds: 1500),
    this.windowSize = 50,
  });

  List<MusicMetadata> get songs => _songs;
  bool get loading => _loading;
  bool get recovering => false;
  bool get wantsPlayback => _wantPlayback;
  bool get playing => _playing;
  double get volume => _volume;
  Stream<int?> get indexStream => _indices.stream;
  Stream<Duration> get positionStream => _positions.stream;
  Stream<bool> get playingStream => _playingChanges.stream;
  Stream<Duration?> get durationStream => _durations.stream;
  Stream<double> get volumeStream => _volumes.stream;
  int? get currentIndex => _songs.isEmpty ? null : logicalQueue.index;
  MusicMetadata? get _current =>
      _songs.isEmpty ? null : _songs[logicalQueue.index];
  Duration? get duration {
    final value = _current?.trackDuration;
    return value == null ? null : Duration(milliseconds: value);
  }

  Duration get displayPosition {
    if (!_playing) return _position;
    final position = _position + DateTime.now().difference(_positionAt);
    final limit = duration;
    return limit != null && position > limit ? limit : position;
  }

  /// Starts polling while the app is in the foreground.
  void resume() {
    if (_disposed || _active) return;
    _active = true;
    _poll = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
    _tick = Timer.periodic(tickInterval, (_) {
      if (!_playing) return;
      _positions.add(displayPosition);
      _broadcast();
    });
    unawaited(refresh());
  }

  /// Stops polling; Spotify keeps playing the current window on its own.
  void suspend() {
    _active = false;
    _poll?.cancel();
    _tick?.cancel();
    _poll = null;
    _tick = null;
  }

  Future<void> _serialize(Future<void> Function() action) {
    final result = _pending.then((_) async {
      try {
        await action();
      } on SpotifyException catch (error) {
        _report(error);
      } finally {
        onCheckpoint?.call();
      }
    });
    _pending = result.catchError((Object _) {});
    return result;
  }

  void _resetQueue({int initialIndex = 0}) {
    final albums = <Object, List<int>>{};
    for (var index = 0; index < _songs.length; index++) {
      final song = _songs[index];
      final Object key =
          (song.albumName?.trim().isNotEmpty ?? false) ||
              song.remoteAlbumId != null
          ? albumIdentityOf(song)
          : index;
      albums.putIfAbsent(key, () => []).add(index);
    }
    for (final album in albums.values) {
      album.sort((a, b) {
        final comparison = compareAlbumTracks(_songs[a], _songs[b]);
        return comparison == 0 ? a.compareTo(b) : comparison;
      });
    }
    logicalQueue.reset(
      _songs.length,
      albums: albums.values.toList(),
      initialIndex: initialIndex,
    );
    _window = [];
  }

  void _setPosition(Duration position, {DateTime? at}) {
    _position = position;
    _positionAt = at ?? DateTime.now();
    _positions.add(position);
  }

  void _setPlaying(bool value) {
    if (_playing == value) return;
    _playing = value;
    _playingChanges.add(value);
  }

  void _quiet() {
    _version++;
    _quietUntil = DateTime.now().add(quietPeriod);
  }

  void _select(int index) {
    logicalQueue.index = index;
    _indices.add(index);
    _durations.add(duration);
    final song = _songs[index];
    mediaItem.add(
      MediaItem(
        id: song.identity,
        title: song.trackName ?? '',
        artist: song.trackArtistNames?.join(', '),
        album: song.albumName,
        duration: duration,
        artUri: song.thumbnailPath == null
            ? null
            : Uri.tryParse(song.thumbnailPath!),
      ),
    );
  }

  List<int> _upcoming(int index) {
    final saved = logicalQueue.index;
    final order = [index];
    try {
      while (order.length < windowSize) {
        logicalQueue.index = order.last;
        final next = logicalQueue.next();
        if (next == null || order.contains(next)) break;
        order.add(next);
      }
    } finally {
      logicalQueue.index = saved;
    }
    return order;
  }

  Future<String> _device({bool fresh = false}) async {
    if (!fresh && _deviceId != null) return _deviceId!;
    var devices = await client.devices();
    if (devices.isEmpty && openSpotify != null) {
      await openSpotify!();
      for (var attempt = 0; attempt < 10 && devices.isEmpty; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        devices = await client.devices();
      }
    }
    final usable = devices.where((device) => !device.isRestricted).toList();
    if (usable.isEmpty) throw const SpotifyException('no_device');
    final device = usable.firstWhere(
      (device) => device.isActive,
      orElse: () => usable.firstWhere(
        (device) => device.type.toLowerCase() == 'smartphone',
        orElse: () => usable.first,
      ),
    );
    if (device.volumePercent != null) {
      _volume = device.volumePercent! / 100;
      _volumes.add(_volume);
    }
    return _deviceId = device.id;
  }

  Future<T> _onDevice<T>(Future<T> Function(String device) action) async {
    // A failed lookup already waited for a device; only a stale id retries.
    final device = await _device();
    try {
      return await action(device);
    } on SpotifyException catch (error) {
      if (error.reason != 'no_device') rethrow;
      return action(await _device(fresh: true));
    }
  }

  Future<void> _syncModes(String device) async {
    final repeat = logicalQueue.loopMode == LoopMode.one ? 'track' : 'off';
    if (_remoteRepeat != repeat) {
      await client.setRepeat(repeat, deviceId: device);
      _remoteRepeat = repeat;
    }
    if (_remoteShuffle != false) {
      await client.setShuffle(false, deviceId: device);
      _remoteShuffle = false;
    }
  }

  Future<void> _startAt(int index, {Duration position = Duration.zero}) async {
    _quiet();
    _loading = true;
    _error = null;
    _select(index);
    _window = _upcoming(index);
    _windowPosition = 0;
    _setPosition(position);
    _broadcast();
    try {
      await _onDevice((device) async {
        await client.play(
          deviceId: device,
          uris: [for (final song in _window) _songs[song].songId!],
          positionMs: position.inMilliseconds,
        );
        await _syncModes(device);
      });
      _setPosition(position);
      _setPlaying(true);
    } finally {
      _loading = false;
      _quiet();
      _broadcast();
    }
  }

  Future<void> setSongs(List<MusicMetadata> songs, {bool preload = true}) {
    _wantPlayback = false;
    return _serialize(() async {
      _songs = List.unmodifiable(songs);
      _resetQueue();
      // The new queue is not on the device yet; report it as stopped so a
      // following play() starts it instead of assuming it already plays.
      _setPlaying(false);
      _setPosition(Duration.zero);
      if (songs.isEmpty) {
        mediaItem.add(null);
        _indices.add(null);
      } else {
        _select(0);
      }
      _broadcast();
    });
  }

  Future<void> restoreSongs(
    List<MusicMetadata> songs, {
    required int index,
    required Duration position,
    bool resetOnFailure = false,
  }) async {
    await setSongs(songs, preload: false);
    if (songs.isEmpty) return;
    await _serialize(() async {
      _select(index);
      _setPosition(position);
      _broadcast();
    });
  }

  Future<void> select(int index, {bool startPlaying = true}) {
    if (index < 0 || index >= _songs.length) return Future.value();
    _wantPlayback = startPlaying;
    return _serialize(() async {
      if (index >= _songs.length) return;
      if (startPlaying) {
        await _startAt(index);
      } else {
        _window = [];
        _select(index);
        _setPosition(Duration.zero);
        _broadcast();
      }
    });
  }

  Future<void> reconcileSongs(List<MusicMetadata> songs) =>
      _serialize(() async {
        final identity = _current?.identity;
        final nextIndex = songs.indexWhere((song) => song.identity == identity);
        _songs = List.unmodifiable(songs);
        _resetQueue(initialIndex: nextIndex < 0 ? 0 : nextIndex);
        if (nextIndex >= 0) {
          _indices.add(nextIndex);
        } else {
          if (_playing) {
            await _onDevice((device) => client.pause(deviceId: device));
          }
          _wantPlayback = false;
          _setPlaying(false);
          _setPosition(Duration.zero);
          mediaItem.add(null);
          _indices.add(songs.isEmpty ? null : 0);
        }
        _broadcast();
      });

  @override
  Future<void> play() {
    _wantPlayback = true;
    return _serialize(() async {
      final current = _current;
      if (current == null) return;
      final remote = await client.playerState();
      if (remote != null &&
          remote.trackUri == current.songId &&
          _window.isNotEmpty) {
        _quiet();
        await _onDevice((device) => client.play(deviceId: device));
        _setPlaying(true);
        _quiet();
        _broadcast();
        return;
      }
      await _startAt(logicalQueue.index, position: _position);
    });
  }

  @override
  Future<void> pause() {
    _wantPlayback = false;
    return _serialize(() async {
      _setPosition(displayPosition);
      _setPlaying(false);
      _quiet();
      _broadcast();
      await _onDevice((device) => client.pause(deviceId: device));
      _quiet();
    });
  }

  @override
  Future<void> stop() => pause();

  @override
  Future<void> seek(Duration position) => _serialize(() async {
    _setPosition(position);
    _quiet();
    _broadcast();
    if (_window.isEmpty) return;
    await _onDevice(
      (device) => client.seek(position.inMilliseconds, deviceId: device),
    );
    _setPosition(position);
    _quiet();
  });

  @override
  Future<void> skipToNext() {
    final next = logicalQueue.next();
    return next == null ? Future.value() : select(next);
  }

  @override
  Future<void> skipToPrevious() {
    if (displayPosition > const Duration(seconds: 3)) {
      return seek(Duration.zero);
    }
    final previous = logicalQueue.previous();
    return previous == null ? Future.value() : select(previous);
  }

  @override
  Future<void> skipToQueueItem(int index) => select(index);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _serialize(() async {
        logicalQueue.loopMode = switch (repeatMode) {
          AudioServiceRepeatMode.one => LoopMode.one,
          AudioServiceRepeatMode.all ||
          AudioServiceRepeatMode.group => LoopMode.all,
          AudioServiceRepeatMode.none => LoopMode.off,
        };
        _broadcast();
        if (_window.isEmpty) return;
        await _onDevice(_syncModes);
      });

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _serialize(() async {
        final mode = PlaybackShuffleMode.fromAudioService(shuffleMode);
        if (logicalQueue.shuffleMode == mode) return;
        logicalQueue.setShuffle(mode);
        _broadcast();
        // The window sent to Spotify follows the old order; resend it.
        if (_window.isNotEmpty && _playing) {
          await _startAt(logicalQueue.index, position: displayPosition);
        } else {
          _window = [];
        }
      });

  Future<void> setVolume(double volume) => _serialize(() async {
    _volume = volume.clamp(0, 1);
    _volumes.add(_volume);
    await _onDevice(
      (device) => client.setVolume((_volume * 100).round(), deviceId: device),
    );
  });

  /// Pulls the device state and maps it back onto the logical queue.
  Future<void> refresh() async {
    if (_polling || _disposed) return;
    _polling = true;
    final version = _version;
    try {
      final remote = await client.playerState();
      if (version != _version || DateTime.now().isBefore(_quietUntil)) {
        return;
      }
      await _apply(remote);
    } on SpotifyException catch (error) {
      if (error.reason != 'network' && error.reason != 'rate_limit') {
        _report(error);
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _apply(SpotifyPlayerState? remote) async {
    if (remote == null) {
      _setPosition(displayPosition);
      _setPlaying(false);
      _broadcast();
      return;
    }
    _error = null;
    if (remote.deviceId != null) _deviceId = remote.deviceId;
    _remoteRepeat = remote.repeatState;
    _remoteShuffle = remote.shuffleState;
    final current = _current;
    if (current == null || _window.isEmpty) {
      _setPlaying(false);
      _broadcast();
      return;
    }
    final uri = remote.trackUri;
    if (uri != null && uri != current.songId) {
      final ahead = _window.indexWhere(
        (index) => _songs[index].songId == uri,
        _windowPosition + 1,
      );
      if (ahead >= 0) {
        _windowPosition = ahead;
        _select(_window[ahead]);
        onCheckpoint?.call();
      } else if (_windowPosition == _window.length - 1) {
        // Spotify ran past the window (e.g. Autoplay): continue the queue.
        await _continue(remotePlaying: remote.isPlaying);
        return;
      } else {
        // Something else is playing; this queue is no longer in control.
        _window = [];
        _wantPlayback = false;
        _setPlaying(false);
        _broadcast();
        return;
      }
    } else if (!remote.isPlaying &&
        _wantPlayback &&
        _windowPosition == _window.length - 1 &&
        (remote.progressMs == 0 || _nearEnd(remote, current))) {
      await _continue(remotePlaying: false);
      return;
    } else if (!remote.isPlaying && _playing) {
      _wantPlayback = false;
    } else if (remote.isPlaying) {
      _wantPlayback = true;
    }
    _setPlaying(remote.isPlaying);
    _setPosition(
      Duration(milliseconds: remote.progressMs),
      at: remote.fetchedAt,
    );
    _broadcast();
  }

  bool _nearEnd(SpotifyPlayerState remote, MusicMetadata song) {
    final length = remote.durationMs ?? song.trackDuration;
    return length != null && remote.progressMs >= length - 1500;
  }

  Future<void> _continue({required bool remotePlaying}) async {
    logicalQueue.index = _window[_windowPosition];
    final next = logicalQueue.next(automatic: true);
    if (next == null || !_wantPlayback) {
      _wantPlayback = false;
      _setPlaying(false);
      _broadcast();
      // Pausing an already stopped player is rejected by Spotify (403).
      if (remotePlaying) {
        await _onDevice((device) => client.pause(deviceId: device));
      }
      return;
    }
    await _serialize(() => _startAt(next));
  }

  void _report(SpotifyException error) {
    _error = error.reason;
    if (error.reason == 'no_device') _deviceId = null;
    _setPlaying(false);
    _wantPlayback = false;
    _broadcast();
    onError?.call(error);
  }

  void _broadcast() {
    if (_disposed) return;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          _playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        processingState: _error != null
            ? AudioProcessingState.error
            : _loading
            ? AudioProcessingState.loading
            : _songs.isEmpty
            ? AudioProcessingState.idle
            : AudioProcessingState.ready,
        errorCode: _error == null ? null : 1,
        errorMessage: _error,
        playing: _playing,
        updatePosition: displayPosition,
        repeatMode: switch (logicalQueue.loopMode) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
        shuffleMode: logicalQueue.shuffleMode.audioServiceMode,
      ),
    );
  }

  Future<void> dispose() async {
    onCheckpoint?.call();
    onCheckpoint = null;
    onRestoreFailure = null;
    suspend();
    _disposed = true;
    await Future.wait([
      _indices.close(),
      _positions.close(),
      _playingChanges.close(),
      _durations.close(),
      _volumes.close(),
    ]);
  }
}
