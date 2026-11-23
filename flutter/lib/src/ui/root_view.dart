/// Root shell: status strip, remote-call banner, "return to call"
/// banner, the five tabs, and the error / notice pill.
library;

import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'app_model.dart';
import 'call_view.dart';
import 'contacts_view.dart';
import 'keypad_view.dart';
import 'link_view.dart';
import 'messages_view.dart';
import 'recents_view.dart';
import 'widgets.dart';

class RootView extends StatelessWidget {
  const RootView({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppModelScope.of(context);
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final tabs = <Widget>[
          const RecentsView(),
          const ContactsView(),
          const KeypadView(),
          const MessagesView(),
          const LinkView(),
        ];
        return Stack(
          children: [
            Scaffold(
              appBar: AppBar(
                title: const Text('پل سیم‌کارت'),
                centerTitle: true,
              ),
          body: Stack(
            children: [
              Column(
                children: [
                  _StatusStrip(model: model),
                  _RemoteCallBanner(model: model),
                  _ReturnToCallBanner(model: model),
                  Expanded(
                    child: IndexedStack(
                      index: model.tabIndex,
                      children: tabs,
                    ),
                  ),
                ],
              ),
              if (model.notice != null || model.lastError != null)
                PositionedDirectional(
                  bottom: 76,
                  start: 0,
                  end: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: () {
                        model.dismissNotice();
                        model.dismissError();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: model.lastError != null
                              ? Colors.red.shade700
                              : Colors.green.shade700,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              model.lastError != null
                                  ? Icons.error_outline
                                  : Icons.check_circle_outline,
                              size: 18,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                model.lastError ?? model.notice ?? '',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          bottomNavigationBar: BottomNavigationBar(
            type: BottomNavigationBarType.fixed,
            currentIndex: model.tabIndex,
            onTap: model.selectTab,
            items: [
              BottomNavigationBarItem(
                icon: _BadgedIcon(
                  icon: Icons.history,
                  count: model.missedCount,
                ),
                label: 'تماس‌ها',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.contacts),
                label: 'مخاطبین',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.grid_3x3),
                label: 'شماره‌گیر',
              ),
              BottomNavigationBarItem(
                icon: _BadgedIcon(
                  icon: Icons.message,
                  count: model.unreadTotal,
                ),
                label: 'پیام‌ها',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.link),
                label: 'اتصال',
              ),
            ],
          ),
            ),
            if (model.showCallScreen)
              const Positioned.fill(child: CallView()),
          ],
        );
      },
    );
  }
}

class _BadgedIcon extends StatelessWidget {
  const _BadgedIcon({required this.icon, required this.count});

  final IconData icon;
  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return Icon(icon);
    return Badge(
      label: Text(count > 99 ? '99+' : '$count'),
      child: Icon(icon),
    );
  }
}

/// Thin strip at the top: link state, battery and carrier of the
/// Android phone.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final state = model.linkState;
    final dotColor = switch (state) {
      LinkState.connected => Colors.green,
      LinkState.connecting || LinkState.handshaking => Colors.orange,
      LinkState.unpaired => Colors.grey,
      _ => model.isPaired ? Colors.red : Colors.grey,
    };
    final connected = state.isConnected || model.demoMode;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: model.isPaired && !state.isConnected
          ? Colors.red.withValues(alpha: 0.12)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          StatusDot(color: dotColor, label: state.labelFa),
          const Spacer(),
          if (model.status != null && connected) ...[
            for (final sim in model.sims)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 10),
                child: SimChip(sim: sim, showName: model.sims.length > 1),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  model.charging
                      ? Icons.battery_charging_full
                      : _batteryIcon(model.battery),
                  size: 18,
                  color: model.battery <= 15 && !model.charging
                      ? Colors.red
                      : null,
                ),
                const SizedBox(width: 2),
                Text(
                  '${model.battery}٪',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  IconData _batteryIcon(int p) {
    if (p < 13) return Icons.battery_0_bar;
    if (p < 38) return Icons.battery_1_bar;
    if (p < 63) return Icons.battery_3_bar;
    if (p < 88) return Icons.battery_5_bar;
    return Icons.battery_full;
  }
}

/// A call whose audio is on the other device: one tap moves it here.
class _RemoteCallBanner extends StatelessWidget {
  const _RemoteCallBanner({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final remote = model.remoteCalls;
    if (remote.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final c in remote)
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            color: Colors.indigo,
            child: Row(
              children: [
                const Icon(Icons.swap_horiz, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model.displayName(c.num),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'روی ${c.where ?? 'دستگاه دیگر'}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: () => model.takeCall(c.cid),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.22),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 5),
                  ),
                  child: const Text('انتقال به اینجا'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Green strip while a call is live and the call screen is hidden.
class _ReturnToCallBanner extends StatelessWidget {
  const _ReturnToCallBanner({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final screen = model.callScreen;
    if (screen == null || !screen.isLive || model.showCallScreen) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: model.openCallScreen,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        color: Colors.green.shade700,
        child: Row(
          children: [
            const Icon(Icons.call, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${model.displayName(screen.num)} · ${liveDuration(screen.connectedAt)}',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            const Text(
              'بازگشت به تماس',
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
            const Icon(Icons.chevron_left, color: Colors.white),
          ],
        ),
      ),
    );
  }
}
