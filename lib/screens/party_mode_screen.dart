import 'dart:async';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/party_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Hosts a party: shows the QR code guests scan and the songs they ask for.
class PartyModeScreen extends StatefulWidget {
  const PartyModeScreen({super.key});

  static const routeName = "/party";

  @override
  State<PartyModeScreen> createState() => _PartyModeScreenState();
}

class _PartyModeScreenState extends State<PartyModeScreen> {
  /// The guest, with their note for the DJ when they left one.
  static String _who(PartyRequest request) =>
      request.message.isEmpty ? request.guest : '${request.guest} · “${request.message}”';

  StreamSubscription<void>? _changes;
  bool _starting = false;
  bool _busy = false;
  String? _error;

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _changes = PartyService.changes.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _toggle() async {
    setState(() => _starting = true);
    try {
      PartyService.running ? await PartyService.stop() : await PartyService.start();
    } catch (e) {
      GlobalSnackbar.message((context) => context.l10n.partyNoNetwork);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = PartyService.url;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.partyMode)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Text(context.l10n.partyModeDescription),
          if (_error != null) Text(_error!),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _starting ? null : _toggle,
            icon: Icon(PartyService.running ? TablerIcons.player_stop : TablerIcons.confetti),
            label: Text(PartyService.running ? context.l10n.partyStop : context.l10n.partyStart),
          ),
          if (url != null) ...[
            const SizedBox(height: 16),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: QrImageView(data: url, size: 240, backgroundColor: Colors.white),
              ),
            ),
            const SizedBox(height: 8),
            Text(context.l10n.partyScan, textAlign: TextAlign.center, style: textTheme.titleMedium),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                GlobalSnackbar.message((context) => context.l10n.partyLinkCopied, isConfirmation: true);
              },
              icon: const Icon(TablerIcons.copy),
              label: Text(url, style: textTheme.bodySmall),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.partyAutoAccept),
              subtitle: Text(context.l10n.partyAutoAcceptSubtitle),
              value: PartyService.autoAccept,
              onChanged: (value) => setState(() => PartyService.autoAccept = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.partyVoting),
              subtitle: Text(context.l10n.partyVotingHelp),
              value: PartyService.votingEnabled,
              onChanged: _busy ? null : (value) => setState(() => PartyService.votingEnabled = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.partyShoutOuts),
              subtitle: Text(context.l10n.partyShoutOutsHelp),
              value: PartyService.shoutOuts,
              onChanged: (value) => setState(() => PartyService.shoutOuts = value),
            ),
            if (PartyService.voting.requests.isNotEmpty) ...[
              const Divider(),
              Text(context.l10n.partyBallot, style: textTheme.titleMedium),
              FilledButton(
                onPressed: _busy ? null : () => _action(() => PartyService.queueWinner(now: true)),
                child: Text(context.l10n.partyQueueWinner),
              ),
              for (final request in PartyService.voting.ranked)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(request.track.name ?? ''),
                  subtitle: Text('${_who(request)} · ${request.voters.length} ${context.l10n.partyVotes}'),
                  trailing: IconButton(
                    tooltip: context.l10n.featureRemove,
                    icon: const Icon(Icons.close),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            PartyService.voting.requests.remove(request);
                            PartyService.changes.add(null);
                          }),
                  ),
                ),
            ],
            if (PartyService.pending.isNotEmpty) ...[
              const Divider(),
              Text(context.l10n.partyRequests, style: textTheme.titleMedium),
              for (final request in [...PartyService.pending])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(request.track.name ?? ""),
                  subtitle: Text(
                    "${request.track.artists?.join(", ") ?? request.track.albumArtist ?? ""} · ${_who(request)}",
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: context.l10n.partyDecline,
                        icon: const Icon(TablerIcons.x),
                        onPressed: () => PartyService.decline(request),
                      ),
                      IconButton.filledTonal(
                        tooltip: context.l10n.partyApprove,
                        icon: const Icon(TablerIcons.check),
                        onPressed: _busy ? null : () => _action(() => PartyService.approve(request)),
                      ),
                    ],
                  ),
                ),
            ],
            if (PartyService.added.isNotEmpty) ...[
              const Divider(),
              Text(context.l10n.partyAdded, style: textTheme.titleMedium),
              for (final request in PartyService.added.take(15))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(TablerIcons.playlist_add),
                  title: Text(request.track.name ?? ""),
                  subtitle: Text(_who(request)),
                ),
            ],
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
