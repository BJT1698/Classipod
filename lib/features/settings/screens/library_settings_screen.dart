import 'package:classipod/core/alerts/dialogs.dart';
import 'package:classipod/core/extensions/build_context_extensions.dart';
import 'package:classipod/core/extensions/go_router_extensions.dart';
import 'package:classipod/core/navigation/routes.dart';
import 'package:classipod/core/spotify/spotify_client.dart';
import 'package:classipod/core/spotify/spotify_controller.dart';
import 'package:classipod/features/custom_screen_elements/custom_screen.dart';
import 'package:classipod/features/menu/controller/split_screen_controller.dart';
import 'package:classipod/features/menu/models/split_screen_type.dart';
import 'package:classipod/features/settings/controller/prevent_duplicate_tracks_controller.dart';
import 'package:classipod/features/settings/widgets/settings_list_tile.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum _LibrarySettingsItems {
  spotify,
  refreshLibrary,
  preventDuplicateTracks;

  String title(BuildContext context) => switch (this) {
    spotify => 'Spotify',
    preventDuplicateTracks => context.localization.preventDuplicateTracksTitle,
    refreshLibrary => context.localization.refreshLibrarySettingTitle,
  };

  SplitScreenType get preview => switch (this) {
    spotify => SplitScreenType.subsonic,
    preventDuplicateTracks => SplitScreenType.preventDuplicateTracks,
    refreshLibrary => SplitScreenType.refreshLibrary,
  };
}

class LibrarySettingsScreen extends ConsumerStatefulWidget {
  const LibrarySettingsScreen({super.key});

  @override
  ConsumerState<LibrarySettingsScreen> createState() =>
      _LibrarySettingsScreenState();
}

class _LibrarySettingsScreenState extends ConsumerState<LibrarySettingsScreen>
    with CustomScreen {
  bool _handlingSetting = false;
  @override
  String get routeName => Routes.librarySettings.name;

  @override
  List<_LibrarySettingsItems> get displayItems => _LibrarySettingsItems.values;

  @override
  Future<void> onSelectPressed() =>
      _settingAction(displayItems[selectedDisplayItem]);

  Future<void> _settingAction(_LibrarySettingsItems item) async {
    if (_handlingSetting) return;
    _handlingSetting = true;
    try {
      setState(() => selectedDisplayItem = displayItems.indexOf(item));
      final spotify = ref.read(spotifyControllerProvider.notifier);
      switch (item) {
        case _LibrarySettingsItems.spotify:
          if (ref.read(spotifyControllerProvider).value?.signedIn ?? false) {
            await spotify.signOut();
          } else {
            await spotify.signIn();
          }
          break;
        case _LibrarySettingsItems.preventDuplicateTracks:
          await ref
              .read(preventDuplicateTracksProvider.notifier)
              .setEnabled(!ref.read(preventDuplicateTracksProvider));
          break;
        case _LibrarySettingsItems.refreshLibrary:
          await spotify.refresh();
          break;
      }
    } on SpotifyException catch (error) {
      if (mounted && error.reason != 'cancelled') {
        await Dialogs.showInfoDialog(
          context: context,
          title: 'Spotify',
          content: spotifyErrorMessage(error.reason),
        );
      }
    } finally {
      _handlingSetting = false;
    }
  }

  void _changeSplitScreenType() {
    if (!mounted || context.router.locationNamed != routeName) return;
    ref.read(splitScreenControllerProvider.notifier).changeSplitScreenType =
        displayItems[selectedDisplayItem].preview;
  }

  @override
  Widget build(BuildContext context) {
    _changeSplitScreenType();
    final preventDuplicates = ref.watch(preventDuplicateTracksProvider);
    final spotify = ref.watch(spotifyControllerProvider).value;

    return CupertinoPageScaffold(
      resizeToAvoidBottomInset: false,
      child: Column(
        children: [
          if (spotify?.error != null)
            Padding(
              padding: const EdgeInsets.all(4),
              child: Text(spotifyErrorMessage(spotify!.error!)),
            ),
          Flexible(
            child: CupertinoScrollbar(
              controller: scrollController,
              child: ListView.builder(
                controller: scrollController,
                itemCount: displayItems.length,
                prototypeItem: SettingsListTile(
                  text: '',
                  isSelected: false,
                  onTap: () {},
                ),
                itemBuilder: (context, index) => SettingsListTile(
                  text: displayItems[index].title(context),
                  value: switch (displayItems[index]) {
                    _LibrarySettingsItems.spotify =>
                      spotify?.signedIn ?? false
                          ? context.localization.subsonicOn
                          : context.localization.subsonicOff,
                    _LibrarySettingsItems.preventDuplicateTracks =>
                      preventDuplicates
                          ? context.localization.subsonicOn
                          : context.localization.subsonicOff,
                    _LibrarySettingsItems.refreshLibrary =>
                      spotify?.scanning ?? false
                          ? '${spotify!.indexedSongs}'
                          : null,
                  },
                  isSelected: selectedDisplayItem == index,
                  onTap: () async => _settingAction(displayItems[index]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
