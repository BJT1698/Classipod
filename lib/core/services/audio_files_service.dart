import 'dart:collection';

import 'package:classipod/core/models/music_metadata.dart';
import 'package:classipod/core/spotify/spotify_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final audioFilesServiceProvider =
    AsyncNotifierProvider<
      AudioFilesServiceNotifier,
      UnmodifiableListView<MusicMetadata>
    >(AudioFilesServiceNotifier.new);

class AudioFilesServiceNotifier
    extends AsyncNotifier<UnmodifiableListView<MusicMetadata>> {
  void replaceMetadata(MusicMetadata song) {
    final current = state.value;
    if (current != null) {
      state = AsyncData(
        UnmodifiableListView([
          for (final item in current)
            if (item.identity == song.identity) song else item,
        ]),
      );
    }
  }

  @override
  Future<UnmodifiableListView<MusicMetadata>> build() =>
      getAudioFilesMetadata();

  Future<UnmodifiableListView<MusicMetadata>> getAudioFilesMetadata() async {
    final songs = await ref.watch(
      spotifyControllerProvider.selectAsync((spotify) => spotify.songs),
    );
    return UnmodifiableListView(songs);
  }
}
