import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:classipod/core/spotify/spotify_callback.dart';
import 'package:classipod/core/spotify/spotify_client.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

typedef SpotifyAuthenticator = Future<String> Function(
  String url,
  String callbackUrlScheme,
);

class SpotifyAuth {
  static const redirectUri = 'classipod://spotify-callback';
  static const clientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');
  static const scopes = [
    'user-library-read',
    'playlist-read-private',
    'playlist-read-collaborative',
    'user-read-playback-state',
    'user-modify-playback-state',
    'user-read-currently-playing',
    'user-follow-read',
  ];
  static const _accessKey = 'spotify:access';
  static const _refreshKey = 'spotify:refresh';
  static const _expiryKey = 'spotify:expiry';
  static final _tokenUri = Uri.parse('https://accounts.spotify.com/api/token');

  final FlutterSecureStorage _storage;
  final http.Client _http;
  final String _clientId;
  final SpotifyAuthenticator _authenticate;
  String? _access;
  String? _refresh;
  DateTime? _expiry;
  Future<String>? _refreshing;

  SpotifyAuth({
    FlutterSecureStorage? storage,
    http.Client? httpClient,
    String? clientIdOverride,
    SpotifyAuthenticator? authenticate,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _http = httpClient ?? http.Client(),
       _clientId = clientIdOverride ?? clientId,
       _authenticate = authenticate ?? authenticateInBrowser;

  bool get configured => _clientId.isNotEmpty;

  bool get signedIn => _refresh != null;

  static String randomVerifier([int length = 64]) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  static String challenge(String verifier) => base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');

  Uri authorizeUri(String verifier, String state) =>
      Uri.https('accounts.spotify.com', '/authorize', {
        'client_id': _clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'code_challenge_method': 'S256',
        'code_challenge': challenge(verifier),
        'scope': scopes.join(' '),
        'state': state,
      });

  Future<void> load() async {
    _access = await _storage.read(key: _accessKey);
    _refresh = await _storage.read(key: _refreshKey);
    final expiry = int.tryParse(await _storage.read(key: _expiryKey) ?? '');
    _expiry = expiry == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(expiry);
  }

  Future<void> signIn() async {
    if (!configured) throw const SpotifyException('auth');
    final verifier = randomVerifier();
    final state = randomVerifier(16);
    final String result;
    try {
      result = await _authenticate(
        authorizeUri(verifier, state).toString(),
        'classipod',
      );
    } on PlatformException catch (e) {
      throw SpotifyException(e.code == 'CANCELED' ? 'cancelled' : 'auth');
    }
    final params = Uri.parse(result).queryParameters;
    if (params['error'] == 'access_denied') {
      throw const SpotifyException('cancelled');
    }
    final code = params['code'];
    if (params['state'] != state || code == null || code.isEmpty) {
      throw const SpotifyException('auth');
    }
    await _token({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'client_id': _clientId,
      'code_verifier': verifier,
    });
  }

  Future<void> signOut() async {
    _access = _refresh = _expiry = null;
    for (final key in [_accessKey, _refreshKey, _expiryKey]) {
      await _storage.delete(key: key);
    }
  }

  Future<String> accessToken({bool force = false}) {
    final access = _access;
    final expiry = _expiry;
    if (!force &&
        access != null &&
        expiry != null &&
        expiry.isAfter(DateTime.now().add(const Duration(seconds: 60)))) {
      return Future.value(access);
    }
    final refresh = _refresh;
    if (refresh == null) {
      return Future.error(const SpotifyException('auth'));
    }
    return _refreshing ??= _token({
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
      'client_id': _clientId,
    }).whenComplete(() => _refreshing = null);
  }

  Future<String> _token(Map<String, String> body) async {
    final http.Response response;
    try {
      response = await _http
          .post(_tokenUri, body: body)
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw const SpotifyException('network');
    }
    Object? data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {}
    if (response.statusCode != 200) {
      if (data is Map && data['error'] == 'invalid_grant') {
        await signOut();
        throw SpotifyException('auth', response.statusCode);
      }
      throw SpotifyException(
        response.statusCode == 400 || response.statusCode == 401
            ? 'auth'
            : 'response',
        response.statusCode,
      );
    }
    final access = data is Map ? data['access_token'] : null;
    final expiresIn = data is Map ? data['expires_in'] : null;
    if (access is! String || expiresIn is! num) {
      throw const SpotifyException('response');
    }
    final refresh = (data as Map)['refresh_token'];
    _access = access;
    _expiry = DateTime.now().add(Duration(seconds: expiresIn.toInt()));
    if (refresh is String && refresh.isNotEmpty) _refresh = refresh;
    if (_refresh == null) throw const SpotifyException('response');
    await _storage.write(key: _accessKey, value: access);
    await _storage.write(key: _refreshKey, value: _refresh);
    await _storage.write(
      key: _expiryKey,
      value: '${_expiry!.millisecondsSinceEpoch}',
    );
    return access;
  }
}
