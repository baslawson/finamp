import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/components/headphone_tone_controls.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/genre_eq_service.dart';
import 'package:finamp/services/headphone_eq_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';

final _headphoneIndexProvider = FutureProvider.autoDispose((ref) => HeadphoneEqService.loadIndex());

/// Lets the user pick their headphones and applies the matching AutoEQ correction.
class HeadphoneEqScreen extends ConsumerStatefulWidget {
  const HeadphoneEqScreen({super.key});

  static const routeName = "/settings/headphoneeq";

  @override
  ConsumerState<HeadphoneEqScreen> createState() => _HeadphoneEqScreenState();
}

class _HeadphoneEqScreenState extends ConsumerState<HeadphoneEqScreen> {
  final _equalizer = GetIt.instance<MusicPlayerBackgroundTask>().equalizer;
  // Keeps the text when the field moves down as the active correction card appears above it.
  final _searchController = TextEditingController();
  String _query = "";
  HeadphoneCorrection? _active;
  String? _applying;

  @override
  void initState() {
    super.initState();
    HeadphoneEqService.loadSaved().then((saved) {
      if (mounted) setState(() => _active = saved);
    });
  }

  Future<void> _select(HeadphoneProfile profile) async {
    setState(() => _applying = profile.path);
    try {
      final correction = await HeadphoneEqService.select(profile, _equalizer!);
      if (mounted) setState(() => _active = correction);
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _applying = null);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _turnOff() async {
    await HeadphoneEqService.clear(_equalizer!);
    if (mounted) setState(() => _active = null);
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(_headphoneIndexProvider);
    final results = HeadphoneEqService.search(index.valueOrNull ?? [], _query).take(50).toList();

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.headphoneEq)),
      body: _equalizer == null
          ? Center(child: Text(context.l10n.headphoneEqUnsupported))
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Text(context.l10n.headphoneEqDescription),
                HeadphoneToneControls(equalizer: _equalizer),
                const SizedBox(height: 4),
                StreamBuilder<GenreEqPreset>(
                  stream: GenreEqService.current,
                  builder: (context, preset) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(TablerIcons.adjustments_horizontal),
                    title: Text(context.l10n.genreEq),
                    subtitle: Text(
                      GenreEqService.enabled
                          ? context.l10n.genreEqNow(genreEqPresetName(context, preset.data ?? GenreEqPreset.flat))
                          : context.l10n.genreEqDescription,
                    ),
                    value: GenreEqService.enabled,
                    onChanged: (enabled) async {
                      await GenreEqService.setEnabled(enabled);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
                const SizedBox(height: 8),
                if (_active != null)
                  Card(
                    child: ListTile(
                      leading: const Icon(TablerIcons.headphones),
                      title: Text(_active!.name),
                      subtitle: Text(context.l10n.headphoneEqActive),
                      trailing: TextButton(onPressed: _turnOff, child: Text(context.l10n.headphoneEqOff)),
                    ),
                  ),
                if (_active != null) _BandGains(equalizer: _equalizer),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(TablerIcons.search),
                    hintText: context.l10n.headphoneEqSearchHint,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (query) => setState(() => _query = query),
                ),
                if (index.isLoading) const LinearProgressIndicator(),
                if (index.hasError) Text(index.error.toString()),
                for (final profile in results)
                  ListTile(
                    title: Text(profile.name),
                    subtitle: Text(profile.source),
                    selected: _active?.path == profile.path,
                    trailing: _applying == profile.path
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : null,
                    onTap: _applying == null ? () => _select(profile) : null,
                  ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

/// Shows the gain of each device equalizer band.
class _BandGains extends StatelessWidget {
  const _BandGains({required this.equalizer});

  final AndroidEqualizer equalizer;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: equalizer.parameters,
      builder: (context, snapshot) {
        final parameters = snapshot.data;
        if (parameters == null) return const SizedBox.shrink();
        final colors = Theme.of(context).colorScheme;
        return SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final band in parameters.bands)
                Expanded(
                  child: StreamBuilder<double>(
                    stream: band.gainStream,
                    builder: (context, gain) {
                      final value = gain.data ?? 0;
                      final fraction = (value / parameters.maxDecibels).clamp(-1.0, 1.0);
                      return Column(
                        children: [
                          Text(
                            "${value >= 0 ? "+" : ""}${value.toStringAsFixed(1)}",
                            style: const TextStyle(fontSize: 11),
                          ),
                          Expanded(
                            child: Align(
                              alignment: Alignment(0, -fraction),
                              child: Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(color: colors.primary, shape: BoxShape.circle),
                              ),
                            ),
                          ),
                          Text(_formatFrequency(band.centerFrequency), style: const TextStyle(fontSize: 11)),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _formatFrequency(double hertz) =>
      hertz >= 1000 ? "${(hertz / 1000).toStringAsFixed(hertz >= 10000 ? 0 : 1)}k" : hertz.round().toString();
}

String genreEqPresetName(BuildContext context, GenreEqPreset preset) => switch (preset) {
  GenreEqPreset.flat => context.l10n.genreEqFlat,
  GenreEqPreset.rock => context.l10n.genreEqRock,
  GenreEqPreset.metal => context.l10n.genreEqMetal,
  GenreEqPreset.pop => context.l10n.genreEqPop,
  GenreEqPreset.hipHop => context.l10n.genreEqHipHop,
  GenreEqPreset.electronic => context.l10n.genreEqElectronic,
  GenreEqPreset.jazz => context.l10n.genreEqJazz,
  GenreEqPreset.classical => context.l10n.genreEqClassical,
  GenreEqPreset.acoustic => context.l10n.genreEqAcoustic,
  GenreEqPreset.spoken => context.l10n.genreEqSpoken,
};
