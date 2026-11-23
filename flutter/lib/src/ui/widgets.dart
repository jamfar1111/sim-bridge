/// Shared presentation widgets for the SIM-bridge UI:
/// contact avatars, signal bars, SIM chips.
library;

import 'dart:convert' show base64Decode;

import 'package:material_ui/material_ui.dart';

/// Initials for a display name (first letters of the first two words).
String? initialsOf(String name) {
  final parts =
      name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final first = parts[0].runes.first;
  final second = parts.length > 1 ? parts[1].runes.first : null;
  return String.fromCharCode(first) +
      (second == null ? '' : String.fromCharCode(second));
}

/// Round contact avatar: photo when present, initials otherwise.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.photo, this.size = 40});

  final String name;
  final String? photo;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initials = initialsOf(name);
    return ClipOval(
      child: Container(
        width: size,
        height: size,
        color: Colors.blueGrey.shade400,
        child: photo != null
            ? _PhotoAvatar(photo: photo!, size: size)
            : Center(
                child: initials == null
                    ? Icon(Icons.person, size: size * 0.5, color: Colors.white)
                    : Text(
                        initials,
                        style: TextStyle(
                          fontSize: size * 0.38,
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                        ),
                      ),
              ),
      ),
    );
  }
}

class _PhotoAvatar extends StatelessWidget {
  const _PhotoAvatar({required this.photo, required this.size});

  final String photo;
  final double size;

  @override
  Widget build(BuildContext context) {
    try {
      final bytes = base64Decode(photo);
      return Image.memory(
        bytes,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Icon(
          Icons.person,
          size: size * 0.5,
          color: Colors.white,
        ),
      );
    } catch (_) {
      return Icon(Icons.person, size: size * 0.5, color: Colors.white);
    }
  }
}

/// Four signal bars, like the phone status bar.
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 4; i++)
          Container(
            width: 3,
            height: (4 + i * 2).toDouble(),
            margin: const EdgeInsetsDirectional.only(end: 1),
            decoration: BoxDecoration(
              color: i < level
                  ? Theme.of(context).colorScheme.onSurface
                  : Theme.of(context).disabledColor,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
      ],
    );
  }
}

/// One SIM in the status strip: name, bars, network type, roaming flag.
class SimChip extends StatelessWidget {
  const SimChip({super.key, required this.sim, this.showName = true});

  final Map<String, dynamic> sim;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final hasService = sim['service'] != 'none' && sim['service'] != 'emergency';
    final name = (sim['name'] as String?) ?? '';
    final net = sim['net'] as String?;
    final roaming = sim['roaming'] == true;
    final signal = (sim['signal'] as num?)?.toInt() ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showName && name.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 3),
            child: Text(name, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (hasService) ...[
          SignalBars(level: signal),
          if (net != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 2),
              child: Text(
                net,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          if (roaming)
            const Padding(
              padding: EdgeInsetsDirectional.only(start: 2),
              child: Text('R',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.orange)),
            ),
        ] else
          Text(
            sim['service'] == 'emergency' ? 'SOS' : 'بدون سرویس',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

/// A small coloured dot + label for link state.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// Empty list that still pulls to refresh: a scrollable child is
/// required, so the message sits in a near-full-height box.
class EmptyRefreshable extends StatelessWidget {
  const EmptyRefreshable({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.of(context).size.height - 300,
          child: Center(child: Text(label)),
        ),
      ],
    );
  }
}
