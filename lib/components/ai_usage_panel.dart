import 'dart:async';

import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/ai_provider_health.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/ai_usage.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Today's and this month's AI use per provider, the optional daily limit, and which request AI is paused after
/// failing. Only counts are shown; nothing about what was asked.
class AiUsagePanel extends StatefulWidget {
  const AiUsagePanel({super.key});

  @override
  State<AiUsagePanel> createState() => _AiUsagePanelState();
}

class _AiUsagePanelState extends State<AiUsagePanel> {
  Map<AiProvider, AiUsageCount> _today = const {};
  Map<AiProvider, AiUsageCount> _month = const {};
  Map<AiProvider, AiProviderStatus> _health = const {};
  int _limit = 0;

  @override
  void initState() {
    super.initState();
    AiUsage.changes.addListener(_reload);
    AiProviderHealth.changes.addListener(_reload);
    unawaited(_reload());
  }

  @override
  void dispose() {
    AiUsage.changes.removeListener(_reload);
    AiProviderHealth.changes.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final today = await AiUsage.total();
    final month = await AiUsage.total(days: 30);
    final limit = await AiUsage.dailyLimit();
    final health = {for (final provider in AiProvider.values) provider: await AiProviderHealth.status(provider)};
    if (!mounted) return;
    setState(() {
      _today = today;
      _month = month;
      _limit = limit;
      _health = health;
    });
  }

  String _describe(BuildContext context, AiUsageCount count) {
    final number = NumberFormat.compact();
    return context.l10n.aiUsageCounts(
      count.requests,
      number.format(count.inputTokens + count.outputTokens),
      count.speechRequests,
      (count.speechMilliseconds / 60000).toStringAsFixed(1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final todayRequests = _today.values.fold<int>(0, (sum, count) => sum + count.allRequests);
    final now = DateTime.now();
    final providers = AiProvider.values.where((p) => _month.containsKey(p) || (_health[p]?.failures ?? 0) > 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (providers.isEmpty) Text(context.l10n.aiUsageNone, style: textTheme.bodyMedium),
        for (final provider in providers) ...[
          Text(provider.displayName, style: textTheme.titleSmall),
          if (_today[provider] != null) Text(context.l10n.aiUsageToday(_describe(context, _today[provider]!))),
          if (_month[provider] != null) Text(context.l10n.aiUsageMonth(_describe(context, _month[provider]!))),
          if ((_month[provider]?.failures ?? 0) > 0) Text(context.l10n.aiUsageFailures(_month[provider]!.failures)),
          if (_health[provider]?.pausedAt(now) ?? false)
            Text(
              context.l10n.aiProviderPaused(DateFormat.Hm().format(_health[provider]!.pausedUntil!)),
              style: textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
        ],
        DropdownButtonFormField<int>(
          key: ValueKey(_limit),
          initialValue: AiUsage.limits.contains(_limit) ? _limit : 0,
          decoration: InputDecoration(
            labelText: context.l10n.aiUsageDailyLimit,
            helperText: _limit > 0
                ? context.l10n.aiUsageLimitUsed(todayRequests, _limit)
                : context.l10n.aiUsageLimitHelp,
            helperMaxLines: 3,
          ),
          items: [
            for (final limit in AiUsage.limits)
              DropdownMenuItem(
                value: limit,
                child: Text(limit == 0 ? context.l10n.aiUsageNoLimit : context.l10n.aiUsageLimitValue(limit)),
              ),
          ],
          onChanged: (value) {
            if (value != null) unawaited(AiUsage.setDailyLimit(value));
          },
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            if (_health.values.any((status) => status.failures > 0))
              TextButton(
                onPressed: () => unawaited(AiProviderHealth.reset()),
                child: Text(context.l10n.aiProviderRetryNow),
              ),
            TextButton(onPressed: () => unawaited(AiUsage.reset()), child: Text(context.l10n.aiUsageReset)),
          ],
        ),
      ],
    );
  }
}
