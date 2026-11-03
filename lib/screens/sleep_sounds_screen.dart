import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/sleep_sounds_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Picks a calming sound and plays it under the music or on its own.
class SleepSoundsScreen extends StatefulWidget {
  const SleepSoundsScreen({super.key});

  static const routeName = "/sleepsounds";

  @override
  State<SleepSoundsScreen> createState() => _SleepSoundsScreenState();
}

class _SleepSoundsScreenState extends State<SleepSoundsScreen> {
  SleepSoundSettings? _settings;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    SleepSoundsService.loadSettings().then((settings) {
      if (mounted) setState(() => _settings = settings);
    });
  }

  Future<void> _save(SleepSoundSettings settings) async {
    setState(() => _settings = settings);
    await SleepSoundsService.saveSettings(settings);
  }

  String _name(SleepSound sound) => switch (sound) {
    SleepSound.rain => context.l10n.sleepSoundRain,
    SleepSound.waves => context.l10n.sleepSoundWaves,
    SleepSound.pinkNoise => context.l10n.sleepSoundPinkNoise,
    SleepSound.brownNoise => context.l10n.sleepSoundBrownNoise,
    SleepSound.whiteNoise => context.l10n.sleepSoundWhiteNoise,
  };

  IconData _icon(SleepSound sound) => switch (sound) {
    SleepSound.rain => TablerIcons.cloud_rain,
    SleepSound.waves => TablerIcons.ripple,
    SleepSound.pinkNoise => TablerIcons.wave_sine,
    SleepSound.brownNoise => TablerIcons.wave_square,
    SleepSound.whiteNoise => TablerIcons.wind,
  };

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.sleepSounds)),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Text(context.l10n.sleepSoundsDescription),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final sound in SleepSound.values)
                      ChoiceChip(
                        avatar: Icon(_icon(sound)),
                        label: Text(_name(sound)),
                        selected: settings.sound == sound,
                        onSelected: (_) =>
                            _save((sound: sound, volume: settings.volume, followMusic: settings.followMusic)),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(context.l10n.sleepSoundsVolume, style: textTheme.titleMedium),
                Slider(
                  value: settings.volume,
                  onChanged: (volume) => setState(
                    () => _settings = (sound: settings.sound, volume: volume, followMusic: settings.followMusic),
                  ),
                  onChangeEnd: (volume) =>
                      _save((sound: settings.sound, volume: volume, followMusic: settings.followMusic)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.sleepSoundsFollowMusic),
                  subtitle: Text(context.l10n.sleepSoundsFollowMusicSubtitle),
                  value: settings.followMusic,
                  onChanged: (follow) => _save((sound: settings.sound, volume: settings.volume, followMusic: follow)),
                ),
                const SizedBox(height: 16),
                StreamBuilder<bool>(
                  stream: SleepSoundsService.playing.stream,
                  initialData: SleepSoundsService.isOn,
                  builder: (context, on) => FilledButton.icon(
                    onPressed: _starting
                        ? null
                        : () async {
                            setState(() => _starting = true);
                            try {
                              on.data! ? await SleepSoundsService.stop() : await SleepSoundsService.start();
                            } finally {
                              if (mounted) setState(() => _starting = false);
                            }
                          },
                    icon: _starting
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(on.data! ? TablerIcons.player_stop : TablerIcons.player_play),
                    label: Text(on.data! ? context.l10n.sleepSoundsStop : context.l10n.sleepSoundsPlay),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
