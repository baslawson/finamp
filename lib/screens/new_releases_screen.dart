import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/new_releases_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// New and upcoming albums from the artists you listen to that aren't in the library yet.
class NewReleasesScreen extends StatefulWidget {
  const NewReleasesScreen({super.key});

  static const routeName = "/newreleases";

  @override
  State<NewReleasesScreen> createState() => _NewReleasesScreenState();
}

class _NewReleasesScreenState extends State<NewReleasesScreen> {
  NewReleasesResult? _result;
  bool _loaded = false;
  (int, int)? _progress;

  @override
  void initState() {
    super.initState();
    NewReleasesService.loadCached().then((cached) {
      if (!mounted) return;
      setState(() {
        _result = cached;
        _loaded = true;
      });
      if (cached == null) _check();
    });
  }

  Future<void> _check() async {
    setState(() => _progress = (0, 0));
    try {
      final result = await NewReleasesService.check(
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = (done, total));
        },
      );
      if (mounted) setState(() => _result = result);
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final progress = _progress;
    final localizations = MaterialLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.newReleases),
        actions: [
          IconButton(
            onPressed: progress == null ? _check : null,
            icon: const Icon(TablerIcons.refresh),
            tooltip: context.l10n.newReleasesCheckNow,
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(context.l10n.newReleasesDescription),
                ),
                if (progress != null) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progress.$2 == 0 ? null : progress.$1 / progress.$2),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(context.l10n.newReleasesChecking(progress.$1, progress.$2)),
                  ),
                ],
                if (result != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      context.l10n.newReleasesChecked(result.artists, localizations.formatMediumDate(result.checked)),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (result.releases.isEmpty && progress == null)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(child: Text(context.l10n.newReleasesNone)),
                    ),
                  for (final release in result.releases)
                    ListTile(
                      leading: Icon(release.upcoming ? TablerIcons.calendar_event : TablerIcons.disc),
                      title: Text(release.title),
                      subtitle: Text("${release.artist} · ${release.type} · ${release.date}"),
                      trailing: release.upcoming ? Chip(label: Text(context.l10n.newReleasesUpcoming)) : null,
                      onTap: () => launchUrl(release.url, mode: LaunchMode.externalApplication),
                    ),
                ],
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
