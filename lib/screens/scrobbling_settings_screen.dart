import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/scrobble_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// Connects ListenBrainz and Last.fm, which then get every listen.
class ScrobblingSettingsScreen extends StatefulWidget {
  const ScrobblingSettingsScreen({super.key});

  static const routeName = "/settings/scrobbling";

  @override
  State<ScrobblingSettingsScreen> createState() => _ScrobblingSettingsScreenState();
}

class _ScrobblingSettingsScreenState extends State<ScrobblingSettingsScreen> {
  final _lbToken = TextEditingController();
  final _lfApiKey = TextEditingController();
  final _lfSecret = TextEditingController();
  final _lfUser = TextEditingController();
  final _lfPassword = TextEditingController();
  ScrobbleSettings? _settings;
  int _pending = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    for (final controller in [_lbToken, _lfApiKey, _lfSecret, _lfUser, _lfPassword]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _reload() async {
    final settings = await ScrobbleService.loadSettings();
    final pending = await ScrobbleService.pendingCount();
    if (mounted) {
      setState(() {
        _settings = settings;
        _pending = pending;
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      await _reload();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.scrobbling)),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Text(context.l10n.scrobblingDescription),
                if (_pending > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(child: Text(context.l10n.scrobblingPending(_pending))),
                        TextButton(
                          onPressed: _busy ? null : () => _run(ScrobbleService.flush),
                          child: Text(context.l10n.scrobblingSendNow),
                        ),
                      ],
                    ),
                  ),
                if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
                const SizedBox(height: 16),
                Text("ListenBrainz", style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                if (settings.listenBrainzToken != null)
                  _Connected(
                    user: settings.listenBrainzUser ?? "",
                    onDisconnect: _busy ? null : () => _run(ScrobbleService.disconnectListenBrainz),
                  )
                else ...[
                  Text(context.l10n.scrobblingListenBrainzHelp),
                  TextButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse("https://listenbrainz.org/settings/"),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(TablerIcons.external_link),
                    label: Text(context.l10n.scrobblingGetToken),
                  ),
                  TextField(
                    controller: _lbToken,
                    obscureText: true,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: context.l10n.scrobblingUserToken,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _busy ? null : () => _run(() => ScrobbleService.connectListenBrainz(_lbToken.text)),
                    child: Text(context.l10n.scrobblingConnect),
                  ),
                ],
                const Divider(height: 40),
                Text("Last.fm", style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                if (settings.lastFmReady)
                  _Connected(
                    user: settings.lastFmUser ?? "",
                    onDisconnect: _busy ? null : () => _run(ScrobbleService.disconnectLastFm),
                  )
                else ...[
                  Text(context.l10n.scrobblingLastFmHelp),
                  TextButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse("https://www.last.fm/api/account/create"),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(TablerIcons.external_link),
                    label: Text(context.l10n.scrobblingCreateApiAccount),
                  ),
                  for (final (controller, label, secret) in [
                    (_lfApiKey, context.l10n.scrobblingApiKey, false),
                    (_lfSecret, context.l10n.scrobblingSharedSecret, true),
                    (_lfUser, context.l10n.scrobblingUsername, false),
                    (_lfPassword, context.l10n.scrobblingPassword, true),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextField(
                        controller: controller,
                        obscureText: secret,
                        autocorrect: false,
                        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
                      ),
                    ),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await ScrobbleService.connectLastFm(
                              apiKey: _lfApiKey.text,
                              secret: _lfSecret.text,
                              username: _lfUser.text,
                              password: _lfPassword.text,
                            );
                            _lfPassword.clear();
                          }),
                    child: Text(context.l10n.scrobblingConnect),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

class _Connected extends StatelessWidget {
  const _Connected({required this.user, required this.onDisconnect});

  final String user;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(TablerIcons.circle_check),
        title: Text(context.l10n.scrobblingConnectedAs(user)),
        trailing: TextButton(onPressed: onDisconnect, child: Text(context.l10n.scrobblingDisconnect)),
      ),
    );
  }
}
