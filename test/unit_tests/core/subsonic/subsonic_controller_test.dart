// ignore_for_file: depend_on_referenced_packages
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:classipod/core/constants/constants.dart';
import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/providers/filtered_audio_files_provider.dart';
import 'package:classipod/core/providers/shared_preferences_with_cache_provider.dart';
import 'package:classipod/core/services/audio_files_service.dart';
import 'package:classipod/core/subsonic/subsonic_client.dart';
import 'package:classipod/core/subsonic/subsonic_controller.dart';
import 'package:classipod/core/subsonic/subsonic_credentials.dart';
import 'package:classipod/core/subsonic/subsonic_repository.dart';
import 'package:classipod/features/settings/controller/prevent_duplicate_tracks_controller.dart';
import 'package:classipod/features/settings/models/exclude_directory_model.dart';
import 'package:classipod/hive/hive_registrar.g.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class MemoryCredentials implements SubsonicCredentialStore {
  final passwords = <String, String>{};
  @override
  Future<String?> read(String id) async => passwords[id];
  @override
  Future<void> write(String id, String password) async {
    passwords[id] = password;
  }

  @override
  Future<void> delete(String id) async {
    passwords.remove(id);
  }
}

class _FixedAudioFiles extends AudioFilesServiceNotifier {
  final List<MusicMetadata> songs;

  _FixedAudioFiles(this.songs);

  @override
  Future<UnmodifiableListView<MusicMetadata>> build() async =>
      UnmodifiableListView(songs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ProviderContainer container;
  late MemoryCredentials credentials;
  var failPing = false;
  var requests = 0;
  setUp(() async {
    requests = 0;
    failPing = false;
    directory = await Directory.systemTemp.createTemp('subsonic-controller-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapters();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    credentials = MemoryCredentials();
    container = ProviderContainer(
      overrides: [
        subsonicCredentialsProvider.overrideWithValue(credentials),
        subsonicClientFactoryProvider.overrideWithValue(
          (config, password) => SubsonicClient(
            config,
            password,
            client: MockClient((request) async {
              requests++;
              if (failPing) return http.Response('failed', 401);
              return http.Response(
                jsonEncode({
                  'subsonic-response': {
                    'status': 'ok',
                    'albumList2': {'album': []},
                  },
                }),
                200,
              );
            }),
          ),
        ),
      ],
    );
    await container.read(subsonicControllerProvider.future);
  });
  tearDown(() async {
    container.dispose();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'duplicate toggle persists, applies exclusions first and restores copies',
    () async {
      final box = await Hive.openBox<ExcludeDirectoryModel>(
        Constants.excludedDirectoriesBoxName,
      );
      await box.add(
        ExcludeDirectoryModel(directoryPath: '/excluded', isExcluded: true),
      );
      final songs = [
        MusicMetadata(filePath: '/excluded/song.mp3'),
        MusicMetadata(filePath: '/music/song.mp3'),
        MusicMetadata(filePath: '/copies/SONG.MP3'),
      ];
      final isolated = ProviderContainer(
        overrides: [
          audioFilesServiceProvider.overrideWith(() => _FixedAudioFiles(songs)),
        ],
      );
      addTearDown(isolated.dispose);
      await isolated.read(sharedPreferencesWithCacheProvider.future);
      final subscription = isolated.listen(
        filteredAudioFilesProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      expect(
        await isolated.read(filteredAudioFilesProvider.future),
        songs.skip(1).toList(),
      );
      await isolated
          .read(preventDuplicateTracksProvider.notifier)
          .setEnabled(true);
      expect(await isolated.read(filteredAudioFilesProvider.future), [
        songs[1],
      ]);
      isolated.invalidate(preventDuplicateTracksProvider);
      expect(isolated.read(preventDuplicateTracksProvider), isTrue);
      expect(await isolated.read(filteredAudioFilesProvider.future), [
        songs[1],
      ]);
      await isolated
          .read(preventDuplicateTracksProvider.notifier)
          .setEnabled(false);
      expect(
        await isolated.read(filteredAudioFilesProvider.future),
        songs.skip(1).toList(),
      );
    },
  );

  test('failed edits preserve credentials and the active server', () async {
    final controller = container.read(subsonicControllerProvider.notifier);
    await controller.connect('https://one.test', 'user', 'first');
    await pumpEventQueue();
    final id = container
        .read(subsonicControllerProvider)
        .requireValue
        .config!
        .id;
    failPing = true;
    await expectLater(
      controller.connect('https://two.test', 'user', 'second'),
      throwsA(isA<SubsonicException>()),
    );
    expect(
      container.read(subsonicControllerProvider).requireValue.config!.id,
      id,
    );
    expect(credentials.passwords, {id: 'first'});
    final prefs = await container.read(
      sharedPreferencesWithCacheProvider.future,
    );
    expect(prefs.getString('subsonicConfig'), isNot(contains('first')));
  });

  test(
    'disable blocks stream/artwork and refresh without forgetting login',
    () async {
      final controller = container.read(subsonicControllerProvider.notifier);
      await controller.connect('https://one.test', 'user', 'secret');
      await pumpEventQueue();
      final id = container
          .read(subsonicControllerProvider)
          .requireValue
          .config!
          .id;
      final song = MusicMetadata(serverId: id, remoteSongId: 'song');
      expect(
        (await controller.resolve(song)).uri.queryParameters['id'],
        'song',
      );
      await controller.setEnabled(false);
      final before = requests;
      await controller.refresh();
      await expectLater(
        controller.resolve(song),
        throwsA(isA<SubsonicException>()),
      );
      await expectLater(
        controller.artwork('subsonic://$id/art'),
        throwsA(isA<SubsonicException>()),
      );
      expect(requests, before);
      expect(credentials.passwords[id], 'secret');
      await controller.setEnabled(true);
      await pumpEventQueue();
      expect(
        container.read(subsonicControllerProvider).requireValue.enabled,
        isTrue,
      );
    },
  );

  test(
    'missing session password keeps cached metadata and requires sign-in',
    () async {
      const config = SubsonicConfig('https://one.test', 'user', enabled: true);
      final repository = await container.read(
        subsonicRepositoryProvider.future,
      );
      final song = SubsonicRepository.parseSong(
        {'id': 'song'},
        {'id': 'album'},
        config.id,
      );
      await repository.box.put('catalog:${config.id}', [song]);
      final prefs = await container.read(
        sharedPreferencesWithCacheProvider.future,
      );
      await prefs.setString(
        'subsonicConfig',
        jsonEncode({
          'url': config.url,
          'username': config.username,
          'enabled': true,
        }),
      );
      container.invalidate(subsonicControllerProvider);
      final state = await container.read(subsonicControllerProvider.future);
      expect(state.signedIn, isFalse);
      expect(state.enabled, isTrue);
      expect(state.songs.single.remoteSongId, 'song');
      expect(requests, 0);
    },
  );
}
