import 'dart:convert';

import 'package:classipod/core/spotify/spotify_auth.dart';
import 'package:classipod/core/spotify/spotify_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response token(String access, {String? refresh, int expires = 3600}) =>
    http.Response(
      jsonEncode({
        'access_token': access,
        'expires_in': expires,
        'refresh_token': ?refresh,
      }),
      200,
    );

String expiry(Duration offset) =>
    '${DateTime.now().add(offset).millisecondsSinceEpoch}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();

  group('pkce', () {
    test('S256 challenge matches RFC 7636 vector', () {
      expect(
        SpotifyAuth.challenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('verifier is unreserved and challenge is unpadded base64url', () {
      for (var i = 0; i < 50; i++) {
        final verifier = SpotifyAuth.randomVerifier();
        expect(verifier, matches(RegExp(r'^[A-Za-z0-9\-._~]{64}$')));
        expect(
          SpotifyAuth.challenge(verifier),
          matches(RegExp(r'^[A-Za-z0-9\-_]{43}$')),
        );
      }
    });
  });

  group('sign in', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('exchanges code with verifier and persists tokens', () async {
      late Uri authorize;
      late Map<String, String> form;
      final auth = SpotifyAuth(
        clientIdOverride: 'client',
        httpClient: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://accounts.spotify.com/api/token',
          );
          form = request.bodyFields;
          return token('a1', refresh: 'r1');
        }),
        authenticate: (url, scheme) async {
          expect(scheme, 'classipod');
          authorize = Uri.parse(url);
          final state = authorize.queryParameters['state'];
          return 'classipod://spotify-callback?code=xyz&state=$state';
        },
      );
      await auth.signIn();
      final query = authorize.queryParameters;
      expect(query['response_type'], 'code');
      expect(query['redirect_uri'], SpotifyAuth.redirectUri);
      expect(query['code_challenge_method'], 'S256');
      expect(query['scope'], SpotifyAuth.scopes.join(' '));
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'xyz');
      expect(form['client_id'], 'client');
      expect(
        SpotifyAuth.challenge(form['code_verifier']!),
        query['code_challenge'],
      );
      expect(auth.signedIn, isTrue);
      expect(await auth.accessToken(), 'a1');
      expect(await storage.read(key: 'spotify:refresh'), 'r1');
      final reloaded = SpotifyAuth(clientIdOverride: 'client');
      await reloaded.load();
      expect(reloaded.signedIn, isTrue);
      expect(await reloaded.accessToken(), 'a1');
    });

    test('rejects state mismatch and maps cancellation', () async {
      SpotifyAuth auth(SpotifyAuthenticator authenticate) => SpotifyAuth(
        clientIdOverride: 'client',
        httpClient: MockClient((_) async => fail('no exchange')),
        authenticate: authenticate,
      );
      await expectLater(
        auth((_, _) async => 'classipod://spotify-callback?code=x&state=bad')
            .signIn(),
        throwsA(isA<SpotifyException>().having((e) => e.reason, 'r', 'auth')),
      );
      await expectLater(
        auth((_, _) async => throw PlatformException(code: 'CANCELED'))
            .signIn(),
        throwsA(
          isA<SpotifyException>().having((e) => e.reason, 'r', 'cancelled'),
        ),
      );
      expect(SpotifyAuth(clientIdOverride: '').configured, isFalse);
    });
  });

  group('refresh', () {
    test('refreshes near expiry and persists rotated token', () async {
      FlutterSecureStorage.setMockInitialValues({
        'spotify:access': 'old',
        'spotify:refresh': 'r1',
        'spotify:expiry': expiry(const Duration(seconds: 30)),
      });
      var calls = 0;
      final auth = SpotifyAuth(
        clientIdOverride: 'client',
        httpClient: MockClient((request) async {
          calls++;
          expect(request.bodyFields, {
            'grant_type': 'refresh_token',
            'refresh_token': 'r1',
            'client_id': 'client',
          });
          return token('new', refresh: 'r2');
        }),
      );
      await auth.load();
      final tokens = await Future.wait([
        auth.accessToken(),
        auth.accessToken(),
      ]);
      expect(tokens, ['new', 'new']);
      expect(calls, 1);
      expect(await auth.accessToken(), 'new');
      expect(calls, 1);
      expect(await storage.read(key: 'spotify:refresh'), 'r2');
      expect(await storage.read(key: 'spotify:access'), 'new');
    });

    test('keeps refresh token when not rotated; force refreshes', () async {
      FlutterSecureStorage.setMockInitialValues({
        'spotify:access': 'valid',
        'spotify:refresh': 'r1',
        'spotify:expiry': expiry(const Duration(hours: 1)),
      });
      final auth = SpotifyAuth(
        clientIdOverride: 'client',
        httpClient: MockClient((_) async => token('forced')),
      );
      await auth.load();
      expect(await auth.accessToken(), 'valid');
      expect(await auth.accessToken(force: true), 'forced');
      expect(await storage.read(key: 'spotify:refresh'), 'r1');
    });

    test('invalid_grant clears tokens', () async {
      FlutterSecureStorage.setMockInitialValues({
        'spotify:refresh': 'revoked',
        'other': 'kept',
      });
      final auth = SpotifyAuth(
        clientIdOverride: 'client',
        httpClient: MockClient(
          (_) async => http.Response('{"error":"invalid_grant"}', 400),
        ),
      );
      await auth.load();
      await expectLater(
        auth.accessToken(),
        throwsA(isA<SpotifyException>().having((e) => e.reason, 'r', 'auth')),
      );
      expect(auth.signedIn, isFalse);
      expect(await storage.read(key: 'spotify:refresh'), isNull);
      expect(await storage.read(key: 'other'), 'kept');
    });

    test('not signed in throws auth; network errors map', () async {
      FlutterSecureStorage.setMockInitialValues({'spotify:refresh': 'r'});
      final auth = SpotifyAuth(
        clientIdOverride: 'client',
        httpClient: MockClient((_) async => throw http.ClientException('x')),
      );
      await expectLater(
        auth.accessToken(),
        throwsA(isA<SpotifyException>().having((e) => e.reason, 'r', 'auth')),
      );
      await auth.load();
      await expectLater(
        auth.accessToken(),
        throwsA(
          isA<SpotifyException>().having((e) => e.reason, 'r', 'network'),
        ),
      );
      expect(auth.signedIn, isTrue);
      await auth.signOut();
      expect(auth.signedIn, isFalse);
    });
  });
}
