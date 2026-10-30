// ignore_for_file: depend_on_referenced_packages
import 'package:audio_service/audio_service.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/services/playback/spotify_audio_handler.dart';
import 'package:classipod/core/spotify/spotify_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Play = ({String? device, List<String>? uris, int? positionMs});

class _FakeSpotifyClient extends Fake implements SpotifyClient {
  List<SpotifyDevice> devicesList = const [
    SpotifyDevice(id: 'computer', name: 'PC', type: 'Computer'),
    SpotifyDevice(id: 'phone', name: 'Phone', type: 'Smartphone'),
  ];
  SpotifyPlayerState? state;
  final List<SpotifyException> playErrors = [];
  final List<_Play> plays = [];
  final List<String> calls = [];
  int devicesCalls = 0;

  @override
  Future<List<SpotifyDevice>> devices() async {
    devicesCalls++;
    return devicesList;
  }

  @override
  Future<SpotifyPlayerState?> playerState() async => state;

  @override
  Future<void> play({
    String? deviceId,
    List<String>? uris,
    int? offset,
    int? positionMs,
  }) async {
    plays.add((device: deviceId, uris: uris, positionMs: positionMs));
    if (playErrors.isNotEmpty) throw playErrors.removeAt(0);
  }

  @override
  Future<void> pause({String? deviceId}) async => calls.add('pause $deviceId');

  @override
  Future<void> seek(int positionMs, {String? deviceId}) async =>
      calls.add('seek $positionMs $deviceId');

  @override
  Future<void> setRepeat(String state, {String? deviceId}) async =>
      calls.add('repeat $state $deviceId');

  @override
  Future<void> setShuffle(bool enabled, {String? deviceId}) async =>
      calls.add('shuffle $enabled $deviceId');
}

String uri(int index) => 'spotify:track:$index';

List<MusicMetadata> songs(int count) => [
  for (var index = 0; index < count; index++)
    MusicMetadata(
      songId: uri(index),
      trackName: '$index',
      trackDuration: 60000,
    ),
];

SpotifyPlayerState remote(
  int? track, {
  bool playing = true,
  int progress = 100,
  String? trackUri,
}) => SpotifyPlayerState(
  deviceId: 'phone',
  isPlaying: playing,
  trackUri: trackUri ?? (track == null ? null : uri(track)),
  progressMs: progress,
  durationMs: 1000,
  repeatState: 'off',
  shuffleState: false,
  fetchedAt: DateTime.now(),
);

void main() {
  late _FakeSpotifyClient client;
  late SpotifyAudioHandler handler;
  final errors = <SpotifyException>[];

  SpotifyAudioHandler create({int windowSize = 50}) {
    final created = SpotifyAudioHandler(
      client,
      windowSize: windowSize,
      quietPeriod: Duration.zero,
    )..onError = errors.add;
    addTearDown(created.dispose);
    return created;
  }

  setUp(() {
    errors.clear();
    client = _FakeSpotifyClient();
    handler = create();
  });

  group('select', () {
    test('sends the window from the index and syncs modes once', () async {
      await handler.setSongs(songs(60));
      await handler.select(5);
      expect(client.plays.single.device, 'phone');
      expect(client.plays.single.uris, [for (var i = 5; i < 55; i++) uri(i)]);
      expect(client.plays.single.positionMs, 0);
      expect(client.calls, ['repeat off phone', 'shuffle false phone']);
      expect(handler.playing, isTrue);
      expect(handler.currentIndex, 5);
      await handler.select(57);
      expect(client.plays.last.uris, [uri(57), uri(58), uri(59)]);
      expect(client.calls, hasLength(2));
      expect(client.devicesCalls, 1);
    });

    test('prefers the active device', () async {
      client.devicesList = const [
        SpotifyDevice(id: 'phone', name: 'Phone', type: 'Smartphone'),
        SpotifyDevice(
          id: 'speaker',
          name: 'Speaker',
          type: 'Speaker',
          isActive: true,
        ),
      ];
      await handler.setSongs(songs(3));
      await handler.select(0);
      expect(client.plays.single.device, 'speaker');
    });

    test('a new queue is not reported as playing until started', () async {
      await handler.setSongs(songs(3));
      await handler.select(1);
      await handler.setSongs(songs(2));
      expect(handler.playing, isFalse);
      client.state = remote(1);
      await handler.play();
      expect(client.plays.last.uris, [uri(0), uri(1)]);
      expect(handler.playing, isTrue);
    });
  });

  group('polling', () {
    test('follows the device through the window', () async {
      await handler.setSongs(songs(5));
      await handler.select(0);
      final indices = <int?>[];
      final subscription = handler.indexStream.listen(indices.add);
      addTearDown(subscription.cancel);
      client.state = remote(1);
      await handler.refresh();
      client.state = remote(3, progress: 400);
      await handler.refresh();
      await pumpEventQueue();
      expect(handler.currentIndex, 3);
      expect(indices, [1, 3]);
      expect(handler.displayPosition.inMilliseconds, greaterThanOrEqualTo(400));
      expect(client.plays, hasLength(1));
    });

    test('continues with the next window at the end of one', () async {
      handler = create(windowSize: 2);
      await handler.setSongs(songs(5));
      await handler.select(0);
      client.state = remote(1);
      await handler.refresh();
      client.state = remote(1, playing: false, progress: 0);
      await handler.refresh();
      expect(client.plays.last.uris, [uri(2), uri(3)]);
      expect(handler.currentIndex, 2);
      expect(handler.playing, isTrue);
    });

    test('stops at the end of the list without repeat', () async {
      handler = create(windowSize: 2);
      await handler.setSongs(songs(3));
      await handler.select(1);
      client.state = remote(2);
      await handler.refresh();
      client.state = remote(2, playing: false, progress: 0);
      await handler.refresh();
      expect(client.plays, hasLength(1));
      expect(handler.playing, isFalse);
      expect(handler.wantsPlayback, isFalse);
      // The device already stopped; pausing it again would be refused.
      expect(client.calls, isNot(contains('pause phone')));
      expect(errors, isEmpty);
    });

    test('pauses Autoplay that runs past the end of the list', () async {
      await handler.setSongs(songs(2));
      await handler.select(0);
      client.state = remote(1);
      await handler.refresh();
      client.state = remote(null, trackUri: 'spotify:track:autoplay');
      await handler.refresh();
      expect(client.calls.last, 'pause phone');
      expect(handler.playing, isFalse);
    });

    test('an external track releases control', () async {
      await handler.setSongs(songs(5));
      await handler.select(0);
      client.state = remote(null, trackUri: 'spotify:track:other');
      await handler.refresh();
      expect(handler.playing, isFalse);
      expect(handler.wantsPlayback, isFalse);
      expect(handler.currentIndex, 0);
      expect(client.calls, isNot(contains('pause phone')));
      client.state = remote(null, trackUri: 'spotify:track:other');
      await handler.refresh();
      expect(handler.playing, isFalse);
    });
  });

  test('shuffle while playing resends from the current position', () async {
    await handler.setSongs(songs(10));
    await handler.select(2);
    client.state = remote(2, progress: 30000);
    await handler.refresh();
    await handler.setShuffleMode(AudioServiceShuffleMode.all);
    final play = client.plays.last;
    expect(client.plays, hasLength(2));
    expect(play.uris!.first, uri(2));
    expect(play.uris!.toSet(), {for (var i = 0; i < 10; i++) uri(i)});
    expect(play.positionMs, inInclusiveRange(30000, 31000));
    expect(handler.currentIndex, 2);
    await handler.pause();
    await handler.setShuffleMode(AudioServiceShuffleMode.none);
    expect(client.plays, hasLength(2));
  });

  group('devices', () {
    test('no_device refetches devices and retries once', () async {
      client.playErrors.add(const SpotifyException('no_device'));
      await handler.setSongs(songs(2));
      await handler.select(0);
      expect(client.plays, hasLength(2));
      expect(client.devicesCalls, 2);
      expect(handler.playing, isTrue);
      expect(errors, isEmpty);
    });

    test('opens Spotify and reports no_device when none appears', () {
      fakeAsync((async) {
        var opened = 0;
        client = _FakeSpotifyClient()..devicesList = const [];
        handler = SpotifyAudioHandler(
          client,
          quietPeriod: Duration.zero,
          openSpotify: () async => opened++,
        )..onError = errors.add;
        handler.setSongs(songs(2)).ignore();
        async.flushMicrotasks();
        handler.select(0).ignore();
        async.elapse(const Duration(seconds: 11));
        expect(opened, 1);
        expect(client.devicesCalls, 11);
        expect(client.plays, isEmpty);
        expect(errors.single.reason, 'no_device');
        expect(handler.playing, isFalse);
        handler.dispose().ignore();
        async.flushMicrotasks();
      });
    });
  });

  group('controls', () {
    setUp(() async {
      await handler.setSongs(songs(5));
      await handler.select(2);
      client.calls.clear();
    });

    test('pause and seek target the device', () async {
      await handler.seek(const Duration(milliseconds: 700));
      await handler.pause();
      expect(client.calls, ['seek 700 phone', 'pause phone']);
      expect(handler.playing, isFalse);
    });

    test('previous restarts the song after three seconds', () async {
      client.state = remote(2, progress: 10000);
      await handler.refresh();
      await handler.skipToPrevious();
      expect(client.calls, ['seek 0 phone']);
      expect(client.plays, hasLength(1));
      await handler.skipToPrevious();
      expect(client.plays.last.uris!.first, uri(1));
      expect(handler.currentIndex, 1);
    });
  });
}
