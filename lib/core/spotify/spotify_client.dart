import 'dart:async';
import 'dart:convert';

import 'package:classipod/core/spotify/spotify_auth.dart';
import 'package:http/http.dart' as http;

class SpotifyException implements Exception {
  final String reason;
  final int? status;
  const SpotifyException(this.reason, [this.status]);
  @override
  String toString() => 'Spotify: $reason${status == null ? '' : ' ($status)'}';
}

class SpotifyDevice {
  final String id, name, type;
  final bool isActive, isRestricted;
  final int? volumePercent;
  final bool supportsVolume;
  const SpotifyDevice({
    required this.id,
    required this.name,
    required this.type,
    this.isActive = false,
    this.isRestricted = false,
    this.volumePercent,
    this.supportsVolume = false,
  });
}

class SpotifyPlayerState {
  final String? deviceId;
  final bool isPlaying;
  final String? trackUri;
  final int progressMs;
  final int? durationMs;
  final String repeatState;
  final bool shuffleState;
  final DateTime fetchedAt;
  const SpotifyPlayerState({
    required this.deviceId,
    required this.isPlaying,
    required this.trackUri,
    required this.progressMs,
    required this.durationMs,
    required this.repeatState,
    required this.shuffleState,
    required this.fetchedAt,
  });
}

class SpotifyClient {
  static const base = 'https://api.spotify.com/v1';
  static const maxRetryAfter = Duration(seconds: 30);

  final SpotifyAuth auth;
  final http.Client _http;
  final Future<void> Function(Duration) _delay;

  SpotifyClient(
    this.auth, {
    http.Client? httpClient,
    Future<void> Function(Duration)? delay,
  }) : _http = httpClient ?? http.Client(),
       _delay = delay ?? Future<void>.delayed;

  Uri _uri(String path, Map<String, String>? query) {
    if (path.startsWith('https://')) {
      if (!path.startsWith('$base/')) {
        throw const SpotifyException('response');
      }
      return Uri.parse(path);
    }
    final uri = Uri.parse('$base$path');
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: {...uri.queryParameters, ...query});
  }

  Future<http.Response> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = _uri(path, query);
    var refreshed = false;
    var waited = false;
    while (true) {
      final token = await auth.accessToken(force: refreshed);
      final http.Response response;
      try {
        final request = http.Request(method, uri)
          ..headers['Authorization'] = 'Bearer $token';
        if (body != null) {
          request
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode(body);
        }
        response = await _http
            .send(request)
            .then(http.Response.fromStream)
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        throw const SpotifyException('network');
      }
      final status = response.statusCode;
      if (status >= 200 && status < 300) return response;
      if (status == 401 && !refreshed) {
        refreshed = true;
        continue;
      }
      if (status == 429) {
        final wait = Duration(
          seconds: int.tryParse(response.headers['retry-after'] ?? '') ?? 1,
        );
        if (waited || wait > maxRetryAfter) {
          throw const SpotifyException('rate_limit', 429);
        }
        waited = true;
        await _delay(wait);
        continue;
      }
      throw _error(response, path);
    }
  }

  static SpotifyException _error(http.Response response, String path) {
    final status = response.statusCode;
    String? reason;
    try {
      final error = jsonDecode(utf8.decode(response.bodyBytes))['error'];
      if (error is Map) reason = error['reason']?.toString();
    } catch (_) {}
    final player = path.startsWith('/me/player');
    return SpotifyException(switch (status) {
      401 => 'auth',
      403 when reason == 'PREMIUM_REQUIRED' => 'premium',
      403 => 'forbidden',
      404 when reason == 'NO_ACTIVE_DEVICE' || player => 'no_device',
      404 => 'not_found',
      _ => 'response',
    }, status);
  }

  static Map<String, dynamic> _json(http.Response response) {
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is Map<String, dynamic>) return data;
    } catch (_) {}
    throw SpotifyException('response', response.statusCode);
  }

  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, String>? query,
  ]) async => _json(await send('GET', path, query: query));

  Stream<Map<String, dynamic>> paged(
    String path, {
    int limit = 50,
    Map<String, String>? query,
  }) async* {
    String? next = path;
    var first = true;
    while (next != null) {
      final page = await get(
        next,
        first ? {'limit': '$limit', ...?query} : null,
      );
      first = false;
      final listing = page['items'] is List
          ? page
          : page.values.whereType<Map<String, dynamic>>().firstWhere(
              (value) => value['items'] is List,
              orElse: () => throw const SpotifyException('response'),
            );
      for (final item in listing['items'] as List) {
        if (item is Map<String, dynamic>) yield item;
      }
      final link = listing['next'];
      next = link is String && link.isNotEmpty ? link : null;
    }
  }

  Future<SpotifyPlayerState?> playerState() async {
    final http.Response response;
    try {
      response = await send('GET', '/me/player');
    } on SpotifyException catch (e) {
      if (e.reason == 'no_device') return null;
      rethrow;
    }
    if (response.statusCode == 204 || response.bodyBytes.isEmpty) {
      return null;
    }
    final data = _json(response);
    final device = data['device'];
    final item = data['item'];
    return SpotifyPlayerState(
      deviceId: device is Map ? device['id']?.toString() : null,
      isPlaying: data['is_playing'] == true,
      trackUri: item is Map ? item['uri']?.toString() : null,
      progressMs: (data['progress_ms'] as num?)?.toInt() ?? 0,
      durationMs: item is Map ? (item['duration_ms'] as num?)?.toInt() : null,
      repeatState: data['repeat_state']?.toString() ?? 'off',
      shuffleState: data['shuffle_state'] == true,
      fetchedAt: DateTime.now(),
    );
  }

  Future<List<SpotifyDevice>> devices() async {
    final data = await get('/me/player/devices');
    return [
      for (final device in data['devices'] as List? ?? [])
        if (device is Map && device['id'] is String)
          SpotifyDevice(
            id: device['id'] as String,
            name: device['name']?.toString() ?? '',
            type: device['type']?.toString() ?? '',
            isActive: device['is_active'] == true,
            isRestricted: device['is_restricted'] == true,
            volumePercent: (device['volume_percent'] as num?)?.toInt(),
            supportsVolume: device['supports_volume'] == true,
          ),
    ];
  }

  Future<void> _player(
    String method,
    String endpoint, {
    String? deviceId,
    Map<String, String>? query,
    Object? body,
  }) async {
    await send(
      method,
      '/me/player$endpoint',
      query: {...?query, 'device_id': ?deviceId},
      body: body,
    );
  }

  Future<void> transfer(String deviceId, {bool play = false}) => _player(
    'PUT',
    '',
    body: {
      'device_ids': [deviceId],
      'play': play,
    },
  );

  Future<void> play({
    String? deviceId,
    List<String>? uris,
    int? offset,
    int? positionMs,
  }) => _player(
    'PUT',
    '/play',
    deviceId: deviceId,
    body: uris == null && positionMs == null
        ? null
        : {
            'uris': ?uris,
            if (uris != null && offset != null) 'offset': {'position': offset},
            'position_ms': ?positionMs,
          },
  );

  Future<void> pause({String? deviceId}) =>
      _player('PUT', '/pause', deviceId: deviceId);

  Future<void> seek(int positionMs, {String? deviceId}) => _player(
    'PUT',
    '/seek',
    deviceId: deviceId,
    query: {'position_ms': '$positionMs'},
  );

  Future<void> setRepeat(String state, {String? deviceId}) =>
      _player('PUT', '/repeat', deviceId: deviceId, query: {'state': state});

  Future<void> setShuffle(bool enabled, {String? deviceId}) => _player(
    'PUT',
    '/shuffle',
    deviceId: deviceId,
    query: {'state': '$enabled'},
  );

  Future<void> setVolume(int percent, {String? deviceId}) => _player(
    'PUT',
    '/volume',
    deviceId: deviceId,
    query: {'volume_percent': '${percent.clamp(0, 100)}'},
  );

  void close() => _http.close();
}
