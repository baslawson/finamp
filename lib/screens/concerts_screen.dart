import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/concert_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

/// Upcoming concerts by the artists you listen to, and the settings for the alerts.
class ConcertsScreen extends StatefulWidget {
  const ConcertsScreen({super.key});

  static const routeName = "/concerts";

  @override
  State<ConcertsScreen> createState() => _ConcertsScreenState();
}

class _ConcertsScreenState extends State<ConcertsScreen> {
  final _apiKey = TextEditingController();
  final _country = TextEditingController();
  final _city = TextEditingController();
  bool _notify = true;
  bool _loaded = false;
  bool _checking = false;
  List<Concert> _concerts = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _country.dispose();
    _city.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await ConcertService.loadSettings();
    final concerts = await ConcertService.saved();
    if (!mounted) return;
    setState(() {
      _apiKey.text = settings.apiKey ?? "";
      _country.text = settings.countryCode;
      _city.text = settings.city ?? "";
      _notify = settings.notify;
      _concerts = concerts;
      _loaded = true;
    });
  }

  Future<void> _save() => ConcertService.saveSettings((
    apiKey: _apiKey.text,
    countryCode: _country.text.isEmpty ? "US" : _country.text,
    city: _city.text,
    notify: _notify,
  ));

  Future<void> _check() async {
    await _save();
    setState(() => _checking = true);
    try {
      final concerts = await ConcertService.check(notify: false);
      if (mounted) setState(() => _concerts = concerts);
      if (concerts.isEmpty) GlobalSnackbar.message((context) => context.l10n.concertsNoneFound);
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    final dateFormat = DateFormat.yMMMEd(Localizations.localeOf(context).toString());
    return Scaffold(
      appBar: AppBar(title: Text(l10n.concerts)),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(l10n.concertsDescription),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse("https://developer.ticketmaster.com/products-and-docs/apis/getting-started/"),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(TablerIcons.external_link),
                    label: Text(l10n.concertsGetKey),
                  ),
                ),
                TextField(
                  controller: _apiKey,
                  decoration: InputDecoration(labelText: l10n.concertsApiKey, border: const OutlineInputBorder()),
                  obscureText: true,
                  autocorrect: false,
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _country,
                        decoration: InputDecoration(
                          labelText: l10n.concertsCountry,
                          border: const OutlineInputBorder(),
                        ),
                        textCapitalization: TextCapitalization.characters,
                        maxLength: 2,
                        onSubmitted: (_) => _save(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _city,
                        decoration: InputDecoration(
                          labelText: l10n.concertsCity,
                          hintText: l10n.concertsCityHint,
                          border: const OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _save(),
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.concertsNotify),
                  subtitle: Text(l10n.concertsNotifyDescription),
                  value: _notify,
                  onChanged: (notify) {
                    setState(() => _notify = notify);
                    _save();
                  },
                ),
                FilledButton.icon(
                  onPressed: _checking ? null : _check,
                  icon: _checking
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(TablerIcons.search),
                  label: Text(l10n.concertsCheckNow),
                ),
                const SizedBox(height: 16),
                if (_concerts.isNotEmpty) Text(l10n.concertsUpcoming, style: textTheme.titleMedium),
                for (final concert in _concerts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(TablerIcons.ticket),
                    title: Text(concert.artist),
                    subtitle: Text(
                      [
                        dateFormat.format(concert.date),
                        [concert.venue, concert.city].nonNulls.join(", "),
                        if (concert.name.toLowerCase() != concert.artist.toLowerCase()) concert.name,
                      ].where((part) => part.isNotEmpty).join("\n"),
                    ),
                    isThreeLine: true,
                    onTap: concert.url == null
                        ? null
                        : () => launchUrl(Uri.parse(concert.url!), mode: LaunchMode.externalApplication),
                  ),
              ],
            ),
    );
  }
}
