import 'dart:convert';

import 'package:classipod/core/spotify/spotify_auth.dart';
import 'package:classipod/core/spotify/spotify_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.Response error(int status, [String? reason]) => json({
  'error': {'status': status, 'message': 'x', 'reason': ?reason},
}, status);

Matcher reason(String reason, [int? status]) => throwsA(
  isA<SpotifyException>()
      .having((e) => e.reason, 'reason', reason)
      .having((e) => e.status, 'status', status),
);

int inAnHour() =>
    DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SpotifyAuth auth;
  late int refreshes;
  final delays = <Duration>[];

  setUp(() async {
    refreshes = 0;
    delays.clear();
    FlutterSecureStorage.setMockInitialValues({
      'spotify:access': 'a0',
      'spotify:refresh': 'r',
      'spotify:expiry': '${inAnHour()}',
    });
    auth = SpotifyAuth(
      clientIdOverride: 'client',
      httpClient: MockClient(
        (_) async =>
            json({'access_token': 'a${++refreshes}', 'expires_in': 3600}),
      ),
    );
    await auth.load();
  });

  SpotifyClient client(
    Future<http.Response> Function(http.Request request) handler,
  ) => SpotifyClient(
    auth,
    httpClient: MockClient(handler),
    delay: (duration) async => delays.add(duration),
  );

  test('sends bearer token and query', () async {
    final result = await client((request) async {
      expect(request.headers['Authorization'], 'Bearer a0');
      expect(
        request.url.toString(),
        'https://api.spotify.com/v1/me/tracks?limit=1',
      );
      return json({'ok': true});
    }).get('/me/tracks', {'limit': '1'});
    expect(result, {'ok': true});
  });

  test('401 forces one refresh and retries', () async {
    final tokens = <String?>[];
    final api = client((request) async {
      tokens.add(request.headers['Authorization']);
      return tokens.length == 1 ? error(401) : json({});
    });
    await api.get('/me');
    expect(tokens, ['Bearer a0', 'Bearer a1']);
    expect(refreshes, 1);
    tokens.clear();
    final always = client((request) async {
      tokens.add(request.headers['Authorization']);
      return error(401);
    });
    await expectLater(always.get('/me'), reason('auth', 401));
    expect(tokens.length, 2);
  });

  test('429 waits Retry-After once then throws', () async {
    var calls = 0;
    final retry = client((_) async {
      calls++;
      return calls == 1
          ? http.Response('', 429, headers: {'retry-after': '3'})
          : json({});
    });
    await retry.get('/me');
    expect(delays, [const Duration(seconds: 3)]);
    calls = 0;
    final limited = client(
      (_) async => http.Response('', 429, headers: {'retry-after': '2'}),
    );
    await expectLater(limited.get('/me'), reason('rate_limit', 429));
    final long = client(
      (_) async => http.Response('', 429, headers: {'retry-after': '3600'}),
    );
    delays.clear();
    await expectLater(long.get('/me'), reason('rate_limit', 429));
    expect(delays, isEmpty);
  });

  test('maps error statuses', () async {
    await expectLater(
      client((_) async => error(404, 'NO_ACTIVE_DEVICE')).play(),
      reason('no_device', 404),
    );
    await expectLater(
      client((_) async => error(404)).pause(),
      reason('no_device', 404),
    );
    await expectLater(
      client((_) async => error(404)).get('/playlists/x/items'),
      reason('not_found', 404),
    );
    await expectLater(
      client((_) async => error(403, 'PREMIUM_REQUIRED')).play(),
      reason('premium', 403),
    );
    await expectLater(
      client((_) async => error(403)).get('/playlists/x/items'),
      reason('forbidden', 403),
    );
    await expectLater(
      client((_) async => error(500)).get('/me'),
      reason('response', 500),
    );
    await expectLater(
      client((_) async => throw http.ClientException('down')).get('/me'),
      reason('network'),
    );
    await expectLater(
      client((_) async => http.Response('nope', 200)).get('/me'),
      reason('response', 200),
    );
  });

  test('paged follows next and yields items', () async {
    final urls = <String>[];
    final items = await client((request) async {
      urls.add(request.url.toString());
      return switch (request.url.queryParameters['offset']) {
        null => json({
          'items': [
            {'n': 1},
            {'n': 2},
          ],
          'next': 'https://api.spotify.com/v1/me/tracks?offset=2&limit=2',
        }),
        _ => json({
          'items': [
            {'n': 3},
          ],
          'next': null,
        }),
      };
    }).paged('/me/tracks', limit: 2).toList();
    expect(items.map((e) => e['n']), [1, 2, 3]);
    expect(urls, [
      'https://api.spotify.com/v1/me/tracks?limit=2',
      'https://api.spotify.com/v1/me/tracks?offset=2&limit=2',
    ]);
    await expectLater(
      client((_) async => json({'items': [], 'next': 'https://evil.test/x'}))
          .paged('/me/tracks')
          .toList(),
      reason('response'),
    );
  });

  test('player state handles 204 and parses body', () async {
    expect(
      await client((_) async => http.Response('', 204)).playerState(),
      isNull,
    );
    final state = await client(
      (_) async => json({
        'device': {'id': 'd1'},
        'is_playing': true,
        'progress_ms': 1200,
        'repeat_state': 'context',
        'shuffle_state': true,
        'item': {'uri': 'spotify:track:1', 'duration_ms': 5000},
      }),
    ).playerState();
    expect(state!.deviceId, 'd1');
    expect(state.isPlaying, isTrue);
    expect(state.trackUri, 'spotify:track:1');
    expect(state.progressMs, 1200);
    expect(state.durationMs, 5000);
    expect(state.repeatState, 'context');
    expect(state.shuffleState, isTrue);
  });

  test('devices skip entries without id', () async {
    final devices = await client(
      (_) async => json({
        'devices': [
          {
            'id': 'p',
            'name': 'Phone',
            'type': 'Smartphone',
            'is_active': true,
            'volume_percent': 40,
            'supports_volume': true,
          },
          {'id': null, 'name': 'Hidden', 'type': 'TV'},
        ],
      }),
    ).devices();
    expect(devices.single.name, 'Phone');
    expect(devices.single.isActive, isTrue);
    expect(devices.single.volumePercent, 40);
  });

  test('player commands build requests and accept empty bodies', () async {
    final requests = <http.Request>[];
    final api = client((request) async {
      requests.add(request);
      return http.Response('', requests.length.isEven ? 204 : 202);
    });
    await api.play(
      deviceId: 'd',
      uris: ['spotify:track:1', 'spotify:track:2'],
      offset: 1,
      positionMs: 500,
    );
    await api.play();
    await api.transfer('d', play: true);
    await api.seek(42, deviceId: 'd');
    await api.setRepeat('track');
    await api.setShuffle(true);
    await api.setVolume(150);
    await api.pause(deviceId: 'd');
    expect(requests.map((r) => '${r.method} ${r.url.path}?${r.url.query}'), [
      'PUT /v1/me/player/play?device_id=d',
      'PUT /v1/me/player/play?',
      'PUT /v1/me/player?',
      'PUT /v1/me/player/seek?position_ms=42&device_id=d',
      'PUT /v1/me/player/repeat?state=track',
      'PUT /v1/me/player/shuffle?state=true',
      'PUT /v1/me/player/volume?volume_percent=100',
      'PUT /v1/me/player/pause?device_id=d',
    ]);
    expect(jsonDecode(requests[0].body), {
      'uris': ['spotify:track:1', 'spotify:track:2'],
      'offset': {'position': 1},
      'position_ms': 500,
    });
    expect(requests[1].body, isEmpty);
    expect(jsonDecode(requests[2].body), {
      'device_ids': ['d'],
      'play': true,
    });
    expect(requests[0].headers['Content-Type'], startsWith('application/json'));
  });
}
