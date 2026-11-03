import 'package:finamp/screens/car_mode_settings_screen.dart';
import 'package:finamp/screens/listening_enhancements_screen.dart';
import 'package:finamp/screens/server_hub_screen.dart';
import 'package:finamp/screens/saved_karaoke_screen.dart';
import 'package:finamp/screens/radio_controls_screen.dart';
import 'package:finamp/screens/karaoke_dashboard_screen.dart';
import 'package:finamp/screens/concerts_screen.dart';
import 'package:finamp/services/lock_screen_lyrics_service.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/screens/night_mode_settings_screen.dart';
import 'package:finamp/screens/crossfade_settings_screen.dart';
import 'package:finamp/screens/library_health_screen.dart';
import 'package:finamp/screens/skipped_songs_screen.dart';
import 'package:finamp/screens/dj_voice_settings_screen.dart';
import 'package:finamp/screens/scrobbling_settings_screen.dart';
import 'package:finamp/components/SettingsScreen/logout_list_tile.dart';
import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/components/finamp_icon.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/menus/client_certificate_authentication_menu.dart';
import 'package:finamp/menus/quick_connect_authorization_menu.dart';
import 'package:finamp/menus/server_sharing_menu.dart';
import 'package:finamp/screens/accessibility_settings_screen.dart';
import 'package:finamp/screens/audio_service_settings_screen.dart';
import 'package:finamp/screens/downloads_settings_screen.dart';
import 'package:finamp/screens/home_screen_settings_screen.dart';
import 'package:finamp/screens/interaction_settings_screen.dart';
import 'package:finamp/screens/language_selection_screen.dart';
import 'package:finamp/screens/layout_settings_screen.dart';
import 'package:finamp/screens/network_settings_screen.dart';
import 'package:finamp/screens/playback_reporting_settings_screen.dart';
import 'package:finamp/screens/quick_settings_screen.dart';
import 'package:finamp/screens/transcoding_settings_screen.dart';
import 'package:finamp/screens/view_selector.dart';
import 'package:finamp/screens/volume_normalization_settings_screen.dart';
import 'package:finamp/screens/headphone_eq_screen.dart';
import 'package:finamp/screens/analyzer_settings_screen.dart';
import 'package:finamp/screens/updates_settings_screen.dart';
import 'package:finamp/screens/bug_reports_settings_screen.dart';
import 'dart:io' show Platform;
import 'package:finamp/services/client_certificate_installer.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:locale_names/locale_names.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  static const routeName = "/settings";

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const repoLink = "https://github.com/finamp-app/finamp";
  static const releaseNotesLink = "https://github.com/finamp-app/finamp/releases";
  static const translationsLink = "https://hosted.weblate.org/projects/finamp";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.settings),
        leading: FinampAppBarBackButton(),
        actions: [
          FinampSettingsHelper.makeSettingsResetButtonWithDialog(
            context,
            FinampSettingsHelper.resetAllSettings,
            isGlobal: true,
          ),
          Semantics.fromProperties(
            properties: SemanticsProperties(label: AppLocalizations.of(context)!.about, button: true),
            excludeSemantics: true,
            container: true,
            child: IconButton(
              icon: const Icon(Icons.info),
              onPressed: () async {
                final localizations = AppLocalizations.of(context)!;
                final applicationLegalese = AppLocalizations.of(context)!.applicationLegalese(repoLink);
                PackageInfo packageInfo = await PackageInfo.fromPlatform();
                if (!context.mounted) return;

                ThemeData theme = Theme.of(context);
                const linkStyle = TextStyle(color: Colors.blue, decoration: TextDecoration.underline);

                showAboutDialog(
                  context: context,
                  applicationName: packageInfo.appName,
                  applicationVersion: packageInfo.version,
                  applicationIcon: Padding(padding: const EdgeInsets.only(top: 8.0), child: FinampIcon(56, 56)),
                  applicationLegalese: applicationLegalese,
                  children: [
                    const SizedBox(height: 20),
                    RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        style: TextStyle(color: theme.textTheme.bodyMedium!.color),
                        children: [
                          TextSpan(
                            text: localizations.finampTagline,
                            style: const TextStyle(fontStyle: FontStyle.italic, fontWeight: FontWeight.w500),
                          ),
                          const TextSpan(text: '\n\n'),
                          TextSpan(text: localizations.aboutContributionPrompt),
                          const TextSpan(text: '\n\n'),
                          TextSpan(text: '${localizations.aboutContributionLink}\n'),
                          TextSpan(
                            text: repoLink,
                            style: linkStyle,
                            recognizer: TapGestureRecognizer()
                              ..onTap = () async {
                                await launchUrl(Uri.parse(repoLink));
                              },
                          ),
                          const TextSpan(text: '\n\n'),
                          TextSpan(text: '${localizations.aboutTranslations}\n'),
                          TextSpan(
                            text: translationsLink,
                            style: linkStyle,
                            recognizer: TapGestureRecognizer()
                              ..onTap = () async {
                                await launchUrl(Uri.parse(translationsLink));
                              },
                          ),
                          const TextSpan(text: '\n\n'),
                          TextSpan(text: '${localizations.aboutReleaseNotes}\n'),
                          TextSpan(
                            text: releaseNotesLink,
                            style: linkStyle,
                            recognizer: TapGestureRecognizer()
                              ..onTap = () async {
                                await launchUrl(Uri.parse(releaseNotesLink));
                              },
                          ),
                          const TextSpan(text: '\n\n\n'),
                          TextSpan(
                            text: localizations.aboutThanks,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: [
          ListTile(
            leading: const Icon(TablerIcons.sparkles),
            title: Text(AppLocalizations.of(context)!.quickSettingsScreen),
            onTap: () => Navigator.of(
              context,
            ).pushNamed(QuickSettingsScreen.routeName, arguments: QuickSettingsScreen.fromSettingsScreen),
          ),
          ListTile(
            leading: const Icon(TablerIcons.home),
            title: Text(AppLocalizations.of(context)!.homeScreenSettingsTitle),
            onTap: () => Navigator.of(context).pushNamed(HomeScreenSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.compress),
            title: Text(AppLocalizations.of(context)!.transcoding),
            onTap: () => Navigator.of(context).pushNamed(TranscodingSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: Text(AppLocalizations.of(context)!.downloadSettings),
            onTap: () => Navigator.of(context).pushNamed(DownloadsSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.wifi),
            title: Text(AppLocalizations.of(context)!.networkSettingsTitle),
            onTap: () => Navigator.of(context).pushNamed(NetworkSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.music_note),
            title: Text(AppLocalizations.of(context)!.audioService),
            onTap: () => Navigator.of(context).pushNamed(AudioServiceSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.cast),
            title: Text(AppLocalizations.of(context)!.playbackReportingSettingsTitle),
            onTap: () => Navigator.of(context).pushNamed(PlaybackReportingSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.equalizer_rounded),
            title: Text(AppLocalizations.of(context)!.volumeNormalizationSettingsTitle),
            onTap: () => Navigator.of(context).pushNamed(VolumeNormalizationSettingsScreen.routeName),
          ),
          if (Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.headphones),
              title: Text(AppLocalizations.of(context)!.headphoneEq),
              onTap: () => Navigator.of(context).pushNamed(HeadphoneEqScreen.routeName),
            ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(AppLocalizations.of(context)!.listeningEnhancements),
            onTap: () => Navigator.of(context).pushNamed(ListeningEnhancementsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.graphic_eq),
            title: Text(AppLocalizations.of(context)!.analyzerSettings),
            onTap: () => Navigator.of(context).pushNamed(AnalyzerSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.radio),
            title: Text(AppLocalizations.of(context)!.radioControls),
            onTap: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RadioControlsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.dns),
            title: const Text('Server hub'),
            subtitle: const Text('TV karaoke, server radio, sync and backups'),
            onTap: () => Navigator.of(context).pushNamed(ServerHubScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: Text(AppLocalizations.of(context)!.karaokeDashboard),
            onTap: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const KaraokeDashboardScreen())),
          ),
          ListTile(
            leading: const Icon(TablerIcons.microphone_2),
            title: Text(AppLocalizations.of(context)!.karaokeSavedLibrary),
            onTap: () => Navigator.of(context).pushNamed(SavedKaraokeScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.stethoscope),
            title: Text(AppLocalizations.of(context)!.libraryHealth),
            onTap: () => Navigator.of(context).pushNamed(LibraryHealthScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.player_skip_forward),
            title: Text(AppLocalizations.of(context)!.skippedSongs),
            onTap: () => Navigator.of(context).pushNamed(SkippedSongsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.arrows_shuffle_2),
            title: Text(AppLocalizations.of(context)!.crossfade),
            onTap: () => Navigator.of(context).pushNamed(CrossfadeSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.microphone_2),
            title: Text(AppLocalizations.of(context)!.djVoice),
            onTap: () => Navigator.of(context).pushNamed(DjVoiceSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.broadcast),
            title: Text(AppLocalizations.of(context)!.scrobbling),
            onTap: () => Navigator.of(context).pushNamed(ScrobblingSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.ticket),
            title: Text(AppLocalizations.of(context)!.concerts),
            onTap: () => Navigator.of(context).pushNamed(ConcertsScreen.routeName),
          ),
          if (Platform.isAndroid) ...[
            ListTile(
              leading: const Icon(TablerIcons.moon),
              title: Text(AppLocalizations.of(context)!.nightMode),
              onTap: () => Navigator.of(context).pushNamed(NightModeSettingsScreen.routeName),
            ),
            ListTile(
              leading: const Icon(TablerIcons.car),
              title: Text(AppLocalizations.of(context)!.carMode),
              onTap: () => Navigator.of(context).pushNamed(CarModeSettingsScreen.routeName),
            ),
            SwitchListTile(
              secondary: const Icon(TablerIcons.lock_square),
              title: Text(AppLocalizations.of(context)!.lockScreenLyrics),
              subtitle: Text(AppLocalizations.of(context)!.lockScreenLyricsDescription),
              value: LockScreenLyricsService.enabled,
              onChanged: (enabled) async {
                if (!await LockScreenLyricsService.setEnabled(enabled)) {
                  GlobalSnackbar.message((context) => AppLocalizations.of(context)!.lockScreenLyricsNoPermission);
                }
                if (mounted) setState(() {});
              },
            ),
          ],
          ListTile(
            leading: const Icon(Icons.gesture),
            title: Text(AppLocalizations.of(context)!.interactions),
            onTap: () => Navigator.of(context).pushNamed(InteractionSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.widgets),
            title: Text(AppLocalizations.of(context)!.layoutAndTheme),
            onTap: () => Navigator.of(context).pushNamed(LayoutSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(TablerIcons.accessible),
            title: Text(AppLocalizations.of(context)!.accessibility),
            onTap: () => Navigator.of(context).pushNamed(AccessibilitySettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.library_music),
            title: Text(AppLocalizations.of(context)!.selectMusicLibraries),
            subtitle: ref.watch(finampSettingsProvider.isOffline)
                ? Text(AppLocalizations.of(context)!.notAvailableInOfflineMode)
                : null,
            enabled: !ref.watch(finampSettingsProvider.isOffline),
            onTap: () => Navigator.of(context).pushNamed(ViewSelector.routeName),
          ),
          if (Platform.isAndroid)
            ListTile(
              leading: const Icon(TablerIcons.download),
              title: Text(AppLocalizations.of(context)!.updates),
              onTap: () => Navigator.of(context).pushNamed(UpdatesSettingsScreen.routeName),
            ),
          ListTile(
            leading: const Icon(TablerIcons.bug),
            title: Text(AppLocalizations.of(context)!.bugReports),
            onTap: () => Navigator.of(context).pushNamed(BugReportsSettingsScreen.routeName),
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(AppLocalizations.of(context)!.language),
            subtitle: Text(
              ref.watch(finampSettingsProvider.locale)?.nativeDisplayLanguage ?? AppLocalizations.of(context)!.system,
            ),
            onTap: () => Navigator.of(context).pushNamed(LanguageSelectionScreen.routeName),
          ),
          Divider(),
          ListTile(
            leading: Icon(TablerIcons.access_point),
            title: Text(AppLocalizations.of(context)!.serverSharingMenuButtonTitle),
            onTap: () => showServerSharingPanel(context: context),
          ),
          ListTile(
            leading: Icon(TablerIcons.lock_bolt),
            title: Text(AppLocalizations.of(context)!.quickConnectAuthorizationMenuButtonTitle),
            onTap: () => showQuickConnectAuthorizationMenu(context: context),
          ),
          ListTile(
            leading: Icon(TablerIcons.certificate),
            title: Text(AppLocalizations.of(context)!.clientCertificate),
            subtitle: Text(
              !ClientCertificateInstaller.isSupported
                  ? AppLocalizations.of(context)!.clientCertificatesUnsupported
                  : ref.watch(finampSettingsProvider.clientCertificate) != null
                  ? AppLocalizations.of(context)!.clientCertificateInstalled
                  : AppLocalizations.of(context)!.clientCertificateUnavailable,
            ),
            enabled: ClientCertificateInstaller.isSupported,
            onTap: () => showClientCertificateMenu(context: context),
          ),
          const LogoutListTile(),
        ],
      ),
    );
  }
}
