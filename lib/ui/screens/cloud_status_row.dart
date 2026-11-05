/// "Connected · last upload 1 min ago" or "Offline: <why>", with a retry,
/// on the host's QR sheet and the seat radar: the one place to look when
/// the TV or the radar sees nothing from the phones.
library;

import 'package:flutter/material.dart';

import '../../sync/table_night_service.dart';
import '../theme.dart';

class CloudStatusRow extends StatelessWidget {
  final CloudStatus status;
  const CloudStatusRow({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final ok = status.connected;
    final colour = ok ? Felt.good : (status.line.startsWith('Connecting') ? Felt.mixed : Theme.of(context).colorScheme.error);
    return Row(key: const Key('cloud-status'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 2, right: 8),
        child: Icon(ok ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, size: 20, color: colour),
      ),
      Expanded(child: SelectableText(status.line, style: t.bodySmall?.copyWith(color: ok ? null : colour))),
      if (!ok)
        TextButton(
          key: const Key('cloud-retry'),
          onPressed: () => TableNightService.instance.retryCloud(),
          child: const Text('Retry'),
        ),
    ]);
  }
}
