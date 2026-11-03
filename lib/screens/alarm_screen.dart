import 'dart:async';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/alarm_service.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

/// Sets the music alarm: when it rings and what it plays.
class AlarmScreen extends StatefulWidget {
  const AlarmScreen({super.key});

  static const routeName = "/alarm";

  @override
  State<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends State<AlarmScreen> with WidgetsBindingObserver {
  AlarmTime? _time;
  AlarmMusic? _music;
  DateTime? _next;
  bool _notificationsAllowed = true;
  bool _fullScreenAllowed = true;
  final _prompt = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _prompt.dispose();
    super.dispose();
  }

  // Permissions may have been changed in Android's settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_checkPermissions());
  }

  Future<void> _load() async {
    final time = await AlarmService.loadTime();
    final music = await AlarmService.loadMusic();
    _prompt.text = music.aiPrompt;
    await _checkPermissions();
    if (!mounted) return;
    setState(() {
      _time = time;
      _music = music;
    });
    if (time.enabled) _next = await AlarmService.saveTime(time);
    if (mounted) setState(() {});
  }

  Future<void> _checkPermissions() async {
    final notifications = await Permission.notification.isGranted;
    final fullScreen = await AlarmService.canUseFullScreenIntent();
    if (mounted) {
      setState(() {
        _notificationsAllowed = notifications;
        _fullScreenAllowed = fullScreen;
      });
    }
  }

  Future<void> _saveTime(AlarmTime time) async {
    setState(() => _time = time);
    if (time.enabled && !_notificationsAllowed) {
      await Permission.notification.request();
      await _checkPermissions();
    }
    final next = await AlarmService.saveTime(time);
    if (!mounted) return;
    setState(() => _next = next);
    if (next != null) {
      GlobalSnackbar.message((context) => context.l10n.alarmSetFor(_untilText(context, next)));
    }
  }

  Future<void> _saveMusic(AlarmMusic music) async {
    setState(() => _music = music);
    await AlarmService.saveMusic(music);
  }

  String _untilText(BuildContext context, DateTime next) {
    final until = next.difference(DateTime.now());
    return context.l10n.alarmRingsIn(until.inHours, until.inMinutes % 60);
  }

  Future<void> _pickPlaylist(AlarmMusic music) async {
    final playlists =
        await GetIt.instance<JellyfinApiHelper>().getItems(
          includeItemTypes: BaseItemDtoType.playlist.jellyfinName,
          recursive: true,
          sortBy: "SortName",
        ) ??
        [];
    if (!mounted) return;
    final picked = await showDialog<BaseItemDto>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.l10n.alarmPickPlaylist),
        children: [
          for (final playlist in playlists)
            SimpleDialogOption(onPressed: () => Navigator.of(context).pop(playlist), child: Text(playlist.name ?? "")),
        ],
      ),
    );
    if (picked != null) {
      await _saveMusic((
        source: AlarmSource.playlist,
        playlistId: picked.id.raw,
        playlistName: picked.name,
        aiPrompt: music.aiPrompt,
        fadeMinutes: music.fadeMinutes,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final time = _time;
    final music = _music;
    if (time == null || music == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final textTheme = Theme.of(context).textTheme;
    final timeOfDay = TimeOfDay(hour: time.hour, minute: time.minute);
    // Monday first, like the bit mask.
    final monday = DateTime(2024, 1, 1);
    final dayNames = [
      for (var day = 0; day < 7; day++)
        DateFormat.E(Localizations.localeOf(context).toString()).format(monday.add(Duration(days: day))),
    ];

    AlarmMusic withMusic({AlarmSource? source, int? fadeMinutes, String? aiPrompt}) => (
      source: source ?? music.source,
      playlistId: music.playlistId,
      playlistName: music.playlistName,
      aiPrompt: aiPrompt ?? music.aiPrompt,
      fadeMinutes: fadeMinutes ?? music.fadeMinutes,
    );

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.alarm)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    final picked = await showTimePicker(context: context, initialTime: timeOfDay);
                    if (picked != null) {
                      await _saveTime((enabled: true, hour: picked.hour, minute: picked.minute, days: time.days));
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      timeOfDay.format(context),
                      style: textTheme.displayMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: time.enabled ? null : Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                ),
              ),
              Switch(
                value: time.enabled,
                onChanged: (enabled) =>
                    _saveTime((enabled: enabled, hour: time.hour, minute: time.minute, days: time.days)),
              ),
            ],
          ),
          Text(
            time.enabled && _next != null ? _untilText(context, _next!) : context.l10n.alarmOff,
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var day = 0; day < 7; day++)
                FilterChip(
                  label: Text(dayNames[day]),
                  selected: time.days & (1 << day) != 0,
                  onSelected: (_) => _saveTime((
                    enabled: time.enabled,
                    hour: time.hour,
                    minute: time.minute,
                    days: time.days ^ (1 << day),
                  )),
                ),
            ],
          ),
          if (time.days == 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(context.l10n.alarmOnce, style: textTheme.bodySmall),
            ),
          if (!_notificationsAllowed || !_fullScreenAllowed)
            Card(
              margin: const EdgeInsets.only(top: 16),
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(TablerIcons.alert_triangle),
                title: Text(
                  !_notificationsAllowed ? context.l10n.alarmNeedsNotifications : context.l10n.alarmNeedsFullScreen,
                ),
                trailing: TextButton(
                  onPressed: () async {
                    if (!_notificationsAllowed) {
                      // Android stops showing the prompt after it was declined, so fall back to the app's settings.
                      if (!await Permission.notification.request().isGranted) await openAppSettings();
                    } else {
                      await AlarmService.openFullScreenIntentSettings();
                    }
                    await _checkPermissions();
                  },
                  child: Text(context.l10n.alarmAllow),
                ),
              ),
            ),
          const Divider(height: 32),
          Text(context.l10n.alarmWakeUpTo, style: textTheme.titleMedium),
          RadioGroup<AlarmSource>(
            groupValue: music.source,
            onChanged: (source) async {
              if (source == AlarmSource.playlist) {
                await _pickPlaylist(music);
              } else if (source != null) {
                await _saveMusic(withMusic(source: source));
              }
            },
            child: Column(
              children: [
                RadioListTile(
                  contentPadding: EdgeInsets.zero,
                  value: AlarmSource.favorites,
                  title: Text(context.l10n.alarmSourceFavorites),
                ),
                RadioListTile(
                  contentPadding: EdgeInsets.zero,
                  value: AlarmSource.shuffleAll,
                  title: Text(context.l10n.alarmSourceShuffleAll),
                ),
                RadioListTile(
                  contentPadding: EdgeInsets.zero,
                  value: AlarmSource.playlist,
                  title: Text(context.l10n.alarmSourcePlaylist),
                  subtitle: music.playlistName == null ? null : Text(music.playlistName!),
                  secondary: music.source == AlarmSource.playlist
                      ? IconButton(
                          icon: const Icon(TablerIcons.edit),
                          tooltip: context.l10n.alarmPickPlaylist,
                          onPressed: () => _pickPlaylist(music),
                        )
                      : null,
                ),
                RadioListTile(
                  contentPadding: EdgeInsets.zero,
                  value: AlarmSource.aiDj,
                  title: Text(context.l10n.alarmSourceAiDj),
                ),
              ],
            ),
          ),
          if (music.source == AlarmSource.aiDj)
            TextField(
              controller: _prompt,
              decoration: InputDecoration(
                labelText: context.l10n.aiDjPrompt,
                hintText: context.l10n.alarmAiDjHint,
                border: const OutlineInputBorder(),
              ),
              onChanged: (prompt) => unawaited(AlarmService.saveMusic(withMusic(aiPrompt: prompt))),
            ),
          const SizedBox(height: 16),
          Text(context.l10n.alarmFadeIn(music.fadeMinutes), style: textTheme.titleMedium),
          Slider(
            value: music.fadeMinutes.toDouble(),
            max: 15,
            divisions: 15,
            onChanged: (minutes) => setState(() => _music = withMusic(fadeMinutes: minutes.round())),
            onChangeEnd: (minutes) => _saveMusic(withMusic(fadeMinutes: minutes.round())),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => AlarmService.ring(Navigator.of(context)),
            icon: const Icon(TablerIcons.alarm),
            label: Text(context.l10n.alarmTest),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
