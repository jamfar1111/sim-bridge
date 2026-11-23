/// Full-screen in-app call screen: incoming / outgoing / active
/// states, answer / decline / end, mute, hold, speaker, DTMF pad,
/// and "Move here" for elsewhere-answered calls.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'app_model.dart';
import 'keypad_view.dart';
import 'widgets.dart';

class CallView extends StatefulWidget {
  const CallView({super.key});

  @override
  State<CallView> createState() => _CallViewState();
}

class _CallViewState extends State<CallView> {
  bool _showDtmf = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Ticks the live duration once a second while a call is active.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = AppModelScope.of(context);
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final screen = model.callScreen;
        if (screen == null) return const SizedBox.shrink();
        final name = screen.name ?? model.nameFor(screen.num);
        final display = name ?? screen.num;
        final stateLabel = switch (screen.state) {
          'ringing' => screen.incoming ? 'تماس ورودی…' : 'در حال زنگ…',
          'dialing' => 'در حال تماس…',
          'connecting' => 'در حال وصل شدن…',
          'active' => liveDuration(screen.connectedAt),
          'holding' => 'در انتظار · ${liveDuration(screen.connectedAt)}',
          'ended' => 'پایان تماس',
          _ => screen.state,
        };
        return Material(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              // Scrollable: with the DTMF pad open the content is far
              // taller than a phone screen (the pad alone is ~720 px),
              // so the column must scroll instead of overflowing.
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: IconButton(
                        key: const ValueKey('call-hide'),
                        icon: const Icon(Icons.keyboard_arrow_down),
                        tooltip: 'پنهان کردن',
                        onPressed: model.closeCallScreen,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Avatar(name: display, size: 96),
                    const SizedBox(height: 16),
                    Text(
                      display,
                      style: Theme.of(context).textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      screen.num,
                      style: Theme.of(context).textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      stateLabel,
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (screen.elsewhere) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.indigo.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('روی ${screen.where ?? 'دستگاه دیگر'}'),
                            const SizedBox(width: 12),
                            FilledButton(
                              key: const ValueKey('call-move-here'),
                              onPressed: () => model.takeCall(screen.uuid),
                              child: const Text('انتقال به اینجا'),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    if (_showDtmf) ...[
                      const DtmfPad(),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () =>
                            setState(() => _showDtmf = false),
                        child: const Text('بستن صفحه‌کلید'),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (screen.state == 'ringing' && screen.incoming)
                      _IncomingActions(screen: screen, model: model)
                    else if (screen.state == 'ended')
                      const SizedBox(height: 64)
                    else
                      _ActiveActions(
                        screen: screen,
                        model: model,
                        showDtmf: _showDtmf,
                        onToggleDtmf: () =>
                            setState(() => _showDtmf = !_showDtmf),
                      ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _IncomingActions extends StatelessWidget {
  const _IncomingActions({required this.screen, required this.model});

  final CallScreen screen;
  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CallActionButton(
          key: const ValueKey('call-decline'),
          icon: Icons.call_end,
          label: 'رد',
          color: Colors.red,
          onPressed: () => model.rejectCall(screen.uuid),
        ),
        _CallActionButton(
          key: const ValueKey('call-answer'),
          icon: Icons.call,
          label: 'پاسخ',
          color: Colors.green,
          onPressed: () => model.answerCall(screen.uuid),
        ),
      ],
    );
  }
}

class _ActiveActions extends StatelessWidget {
  const _ActiveActions({
    required this.screen,
    required this.model,
    required this.showDtmf,
    required this.onToggleDtmf,
  });

  final CallScreen screen;
  final AppModel model;
  final bool showDtmf;
  final VoidCallback onToggleDtmf;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ToggleButton(
              key: const ValueKey('call-mute'),
              icon: screen.muted ? Icons.mic_off : Icons.mic,
              label: 'بی‌صدا',
              active: screen.muted,
              onPressed: model.toggleMute,
            ),
            _ToggleButton(
              key: const ValueKey('call-keypad'),
              icon: Icons.grid_3x3,
              label: 'صفحه‌کلید',
              active: showDtmf,
              onPressed: onToggleDtmf,
            ),
            _ToggleButton(
              key: const ValueKey('call-speaker'),
              icon: Icons.volume_up,
              label: 'بلندگو',
              active: screen.speaker,
              onPressed: model.toggleSpeaker,
            ),
            _ToggleButton(
              key: const ValueKey('call-hold'),
              icon: Icons.pause,
              label: 'انتظار',
              active: screen.held,
              onPressed: model.toggleHold,
            ),
          ],
        ),
        const SizedBox(height: 24),
        _CallActionButton(
          key: const ValueKey('call-end'),
          icon: Icons.call_end,
          label: 'پایان',
          color: Colors.red,
          onPressed: () => model.endCall(screen.uuid),
        ),
      ],
    );
  }
}

class _CallActionButton extends StatelessWidget {
  const _CallActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: label,
          backgroundColor: color,
          onPressed: onPressed,
          child: Icon(icon, color: Colors.white),
        ),
        const SizedBox(height: 6),
        Text(label),
      ],
    );
  }
}

class _ToggleButton extends StatelessWidget {
  const _ToggleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          heroTag: label,
          backgroundColor: active
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          foregroundColor: active
              ? Theme.of(context).colorScheme.onPrimary
              : Theme.of(context).colorScheme.onSurface,
          onPressed: onPressed,
          child: Icon(icon),
        ),
        const SizedBox(height: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
