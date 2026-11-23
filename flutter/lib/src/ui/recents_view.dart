/// Recents tab: call log with direction / missed state, tap to
/// call back.
library;

import 'package:material_ui/material_ui.dart';

import '../protocol/protocol.dart';
import 'app.dart';
import 'app_model.dart';
import 'widgets.dart';

class RecentsView extends StatelessWidget {
  const RecentsView({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppModelScope.of(context);
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final recents = model.recents;
        return RefreshIndicator(
          onRefresh: model.refreshLocalData,
          child: recents.isEmpty
              ? const EmptyRefreshable(label: 'هنوز تماسی نیست')
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: recents.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final entry = recents[i];
                    return _RecentsRow(entry: entry, model: model);
                  },
                ),
        );
      },
    );
  }
}

class _RecentsRow extends StatelessWidget {
  const _RecentsRow({required this.entry, required this.model});

  final CallEntry entry;
  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final name = entry.name ?? model.nameFor(entry.num);
    final display = name ?? entry.num;
    final missed = entry.type == 3;
    final outgoing = entry.type == 2;
    final icon = missed
        ? Icons.call_missed
        : outgoing
            ? Icons.call_made
            : Icons.call_received;
    return InkWell(
      key: ValueKey('recent-${entry.id}'),
      onTap: () => model.dial(entry.num, sub: entry.sub),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Avatar(name: display),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon,
                          size: 16,
                          color: missed ? Colors.red : Colors.grey),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          display,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: missed ? Colors.red : null,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.dur > 0
                        ? '${formatDuration(entry.dur)} · ${shortTime(entry.date)}'
                        : shortTime(entry.date),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              key: ValueKey('call-back-${entry.id}'),
              icon: const Icon(Icons.call),
              tooltip: 'تماس',
              onPressed: () => model.dial(entry.num, sub: entry.sub),
            ),
          ],
        ),
      ),
    );
  }
}
