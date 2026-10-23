import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:finamp/screens/library_health_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// Connects the app to the Finamp+ analyzer running next to Jellyfin.
class AnalyzerSettingsScreen extends StatefulWidget {
  const AnalyzerSettingsScreen({super.key});

  static const routeName = "/settings/analyzer";
  static final setupGuide = Uri.parse("https://github.com/baslawson/finamp/tree/library-search/analyzer");

  @override
  State<AnalyzerSettingsScreen> createState() => _AnalyzerSettingsScreenState();
}

class _AnalyzerSettingsScreenState extends State<AnalyzerSettingsScreen> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  bool _transitions = false;
  bool _harmonic = HarmonicMixing.enabled;
  bool _testing = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    AnalyzerService.getSettings().then((settings) {
      _url.text = settings.url ?? "";
      _token.text = settings.token ?? "";
      if (settings.url != null) _test();
    });
    DjTransitionService.isEnabled().then((enabled) {
      if (mounted) setState(() => _transitions = enabled);
    });
    HarmonicMixing.load().then((enabled) {
      if (mounted) setState(() => _harmonic = enabled);
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await AnalyzerService.saveSettings(url: _url.text, token: _token.text);
    await _test();
  }

  Future<void> _test() async {
    if (!await AnalyzerService.isConfigured()) {
      if (mounted) setState(() => _status = null);
      return;
    }
    setState(() => _testing = true);
    try {
      final status = await AnalyzerService.status();
      if (!mounted) return;
      _status = context.l10n.analyzerStatus(status.analyzed, status.total, status.failed);
      if (status.scanning) _status = "$_status\n${context.l10n.analyzerScanning}";
      if (status.missing > 0) _status = "$_status\n${context.l10n.analyzerMissingFiles(status.missing)}";
    } catch (e) {
      _status = e.toString();
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.analyzerSettings)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Text(context.l10n.analyzerDescription),
          TextButton.icon(
            onPressed: () => launchUrl(AnalyzerSettingsScreen.setupGuide, mode: LaunchMode.externalApplication),
            icon: const Icon(TablerIcons.external_link),
            label: Text(context.l10n.analyzerSetupGuide),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.l10n.analyzerUrl,
              hintText: "http://192.168.1.10:8787",
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            autocorrect: false,
            decoration: InputDecoration(labelText: context.l10n.analyzerToken, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _testing ? null : _save, child: Text(context.l10n.analyzerSaveAndTest)),
          if (_testing) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          if (_status != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_status!)),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.djTransitions),
            subtitle: Text(context.l10n.djTransitionsDescription),
            value: _transitions,
            onChanged: (enabled) async {
              if (enabled && !await AnalyzerService.isConfigured()) {
                GlobalSnackbar.message((context) => context.l10n.analyzerNotSetUp);
              }
              await DjTransitionService.setEnabled(enabled);
              if (mounted) setState(() => _transitions = enabled);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.harmonicMixingRadio),
            subtitle: Text(context.l10n.harmonicMixingDescription),
            value: _harmonic,
            onChanged: (enabled) async {
              if (enabled && !await AnalyzerService.isConfigured()) {
                GlobalSnackbar.message((context) => context.l10n.analyzerNotSetUp);
              }
              await HarmonicMixing.setEnabled(enabled);
              if (mounted) setState(() => _harmonic = enabled);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(TablerIcons.stethoscope),
            title: Text(context.l10n.libraryHealth),
            subtitle: Text(context.l10n.libraryHealthSubtitle),
            onTap: () async {
              if (!await AnalyzerService.isConfigured()) {
                GlobalSnackbar.message((context) => context.l10n.analyzerNotSetUp);
                return;
              }
              if (context.mounted) {
                await Navigator.of(context).pushNamed(LibraryHealthScreen.routeName);
              }
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
