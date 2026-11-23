/// Link tab: pairing status, QR pairing (show + scan), transport
/// status, remote switches and connection info.
library;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../link/link.dart';
import '../log/log.dart';
import '../protocol/protocol.dart';
import '../setup/setup.dart';
import 'app.dart';
import 'app_model.dart';
import 'widgets.dart';

class LinkView extends StatefulWidget {
  const LinkView({super.key});

  @override
  State<LinkView> createState() => _LinkViewState();
}

class _LinkViewState extends State<LinkView> {
  final TextEditingController _codeController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = AppModelScope.of(context);
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (model.setup != null) ...[
              _SetupCard(model: model, setup: model.setup!),
              const SizedBox(height: 16),
            ],
            _StatusCard(model: model),
            const SizedBox(height: 16),
            _TransportCard(model: model),
            const SizedBox(height: 16),
            const _LogCard(),
            if (!model.demoMode) ...[
              const SizedBox(height: 16),
              _WebrtcSettingsCard(model: model),
            ],
            if (model.isIphoneClient) ...[
              const SizedBox(height: 16),
              _BarkCard(model: model),
            ],
            const SizedBox(height: 16),
            if (model.isPaired) ...[
              _PairedCard(model: model),
              const SizedBox(height: 16),
              _SwitchesCard(model: model),
              const SizedBox(height: 16),
              _InfoCard(model: model),
            ] else ...[
              _PairingCard(
                model: model,
                codeController: _codeController,
              ),
            ],
            if (model.demoMode) ...[
              const SizedBox(height: 16),
              _DemoCard(model: model),
            ],
          ],
        );
      },
    );
  }
}

/// First-launch setup card (real mode on Android only): one row
/// per setup item with its state, plus per-item actions and a
/// "request all" button. Refreshes when the tab is shown and after
/// every action; the automatic first-launch run happens in main.dart,
/// this card is the manual re-run path.
class _SetupCard extends StatefulWidget {
  const _SetupCard({required this.model, required this.setup});

  final AppModel model;
  final AndroidSetup setup;

  @override
  State<_SetupCard> createState() => _SetupCardState();
}

class _SetupCardState extends State<_SetupCard> {
  @override
  void initState() {
    super.initState();
    widget.setup.refresh();
  }

  Future<void> _run(
    Future<bool> Function() action,
    String itemLabel, {
    SetupItem? item,
  }) async {
    final ok = await action();
    if (!mounted) return;
    if (ok) {
      widget.model.flash('$itemLabel انجام شد');
    } else {
      widget.model.fail(_failureMessage(item, itemLabel));
    }
  }

  /// What a failed step reports: the real missing item(s), not a
  /// generic "permission denied" — the dialer role is not a
  /// permission at all, and only permanently-denied permissions
  /// need the app-settings screen.
  String _failureMessage(SetupItem? item, String itemLabel) {
    final setup = widget.setup;
    if (item == null) {
      // "Request all": name what is still missing.
      final missing = setup.missingItems;
      if (missing.isEmpty) {
        return '$itemLabel کامل نشد؛ دوباره امتحان کنید.';
      }
      final names = missing.map((i) => i.labelFa).join('، ');
      final settingsHint =
          setup.permanentlyDeniedPermissions.isNotEmpty
              ? ' دسترسی‌های ردشده برای همیشه را فقط از «تنظیمات برنامه» می‌توانید بدهید.'
              : '';
      return '$itemLabel کامل نشد؛ هنوز مانده: $names.$settingsHint';
    }
    switch (item) {
      case SetupItem.dialer:
        return 'انتخاب شماره‌گیر پیش‌فرض کامل نشد؛ از دکمه‌اش در همین کارت دوباره امتحان کنید.';
      case SetupItem.bluetooth:
        return 'روشن کردن بلوتوث کامل نشد؛ دوباره امتحان کنید.';
      case SetupItem.battery:
        return 'درخواست معافیت باتری کامل نشد؛ دوباره امتحان کنید.';
      case SetupItem.permissions:
        if (setup.permanentlyDeniedPermissions.isNotEmpty) {
          return '$itemLabel کامل نشد؛ دسترسی برای همیشه رد شده، از «تنظیمات برنامه» آن را بدهید.';
        }
        return '$itemLabel کامل نشد؛ دوباره امتحان کنید.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final setup = widget.setup;
    return AnimatedBuilder(
      animation: setup,
      builder: (context, _) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('راه‌اندازی',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                const Text(
                  'برای اینکه تماس و پیام به آیفون برسد، این موارد لازم است. '
                  'وضعیت‌ها با باز شدن این تب تازه می‌شوند.',
                ),
                const SizedBox(height: 8),
                _SetupRow(
                  key: const ValueKey('setup-permissions'),
                  item: SetupItem.permissions,
                  done: setup.permissionsGranted,
                  busy: setup.busy,
                  actionLabel: 'درخواست دسترسی‌ها',
                  onAction: () => _run(
                    setup.requestPermissions,
                    'درخواست دسترسی‌ها',
                    item: SetupItem.permissions,
                  ),
                ),
                _SetupRow(
                  key: const ValueKey('setup-bluetooth'),
                  item: SetupItem.bluetooth,
                  done: setup.bluetoothOn,
                  busy: setup.busy,
                  actionLabel: 'روشن کردن بلوتوث',
                  onAction: () => _run(
                    setup.enableBluetooth,
                    'روشن کردن بلوتوث',
                    item: SetupItem.bluetooth,
                  ),
                ),
                _SetupRow(
                  key: const ValueKey('setup-dialer'),
                  item: SetupItem.dialer,
                  done: setup.isDialer,
                  busy: setup.busy,
                  actionLabel: 'انتخاب به‌عنوان شماره‌گیر پیش‌فرض',
                  onAction: () => _run(
                    setup.requestDialer,
                    'انتخاب شماره‌گیر پیش‌فرض',
                    item: SetupItem.dialer,
                  ),
                ),
                _SetupRow(
                  key: const ValueKey('setup-battery'),
                  item: SetupItem.battery,
                  done: setup.batteryExempt,
                  busy: setup.busy,
                  actionLabel: 'درخواست معافیت',
                  onAction: () => _run(
                    setup.requestBatteryExemption,
                    'درخواست معافیت باتری',
                    item: SetupItem.battery,
                  ),
                ),
                if (setup.permanentlyDeniedPermissions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'برخی دسترسی‌ها برای همیشه رد شده‌اند؛ فقط از تنظیمات برنامه می‌توانید آن‌ها را بدهید.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.orange),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('setup-request-all'),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('درخواست همه'),
                      onPressed: setup.busy
                          ? null
                          : () => _run(
                                () async {
                                  await setup.runFullFlow();
                                  return setup.isComplete;
                                },
                                'راه‌اندازی',
                              ),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('setup-open-settings'),
                      icon: const Icon(Icons.settings),
                      label: const Text('تنظیمات برنامه'),
                      onPressed:
                          setup.busy ? null : () => setup.openSettings(),
                    ),
                  ],
                ),
                if (setup.busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SetupRow extends StatelessWidget {
  const _SetupRow({
    super.key,
    required this.item,
    required this.done,
    required this.busy,
    required this.actionLabel,
    required this.onAction,
  });

  final SetupItem item;
  final bool done;
  final bool busy;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        done ? Icons.check_circle : Icons.error_outline,
        color: done ? Colors.green : Colors.orange,
      ),
      title: Text(item.labelFa),
      subtitle: Text(item.hintFa),
      trailing: TextButton(
        key: ValueKey('setup-${item.name}-action'),
        onPressed: busy ? null : onAction,
        child: Text(actionLabel),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.model});

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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusDot(color: dotColor, label: state.labelFa),
            const SizedBox(height: 8),
            Text(
              model.isPaired
                  ? 'گوشی جفت‌شده: ${model.peerName}'
                  : 'هنوز با گوشی اندروید جفت نشده‌اید',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (model.status != null && state.isConnected) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final sim in model.sims)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 12),
                      child: SimChip(sim: sim),
                    ),
                  const Spacer(),
                  Icon(
                    model.charging
                        ? Icons.battery_charging_full
                        : Icons.battery_full,
                    size: 18,
                  ),
                  Text(' ${model.battery}٪'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TransportCard extends StatelessWidget {
  const _TransportCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('مسیر اتصال',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'ble',
                  label: Text('نزدیک · بلوتوث'),
                  icon: Icon(Icons.bluetooth),
                ),
                ButtonSegment(
                  value: 'webrtc',
                  label: Text('دور · اینترنت'),
                  icon: Icon(Icons.public),
                ),
              ],
              selected: {model.transportMode},
              onSelectionChanged: (s) =>
                  model.setTransportMode(s.first),
            ),
            const SizedBox(height: 8),
            Text(
              model.transportMode == 'ble'
                  ? 'وقتی گوشی‌ها نزدیک هم‌اند، صدا و پیام مستقیم از بلوتوث رد می‌شود؛ بدون سرور و بدون اینترنت.'
                  : 'وقتی گوشی‌ها دور از هم‌اند، اتصال از اینترنت برقرار می‌شود (WebRTC با رله TURN کلادفلر)؛ بدون VPN اضافه.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (model.transportMode == 'webrtc' &&
                !WebrtcSettings.isConfigured) ...[
              const SizedBox(height: 8),
              Text(
                'اتصال از راه دور هنوز پیکربندی نشده است: سرور سیگنالینگ باید راه‌اندازی شود تا این مسیر کار کند.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.orange),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PairedCard extends StatelessWidget {
  const _PairedCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('گوشی اندروید',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(model.peerName),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.link_off),
              label: const Text('قطع جفت‌سازی'),
              onPressed: () => model.unpair(),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwitchesCard extends StatelessWidget {
  const _SwitchesCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('کلیدهای گوشی اندروید',
                style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: const Text('اینترنت موبایل'),
              value: model.netState['data'] == true,
              onChanged: (v) => model.setNet('data', v),
            ),
            SwitchListTile(
              title: const Text('هات‌اسپات'),
              value: model.netState['hotspot'] == true,
              onChanged: (v) => model.setNet('hotspot', v),
            ),
            SwitchListTile(
              title: const Text('حالت پرواز'),
              value: model.netState['airplane'] == true,
              onChanged: (v) => model.setNet('airplane', v),
            ),
            SwitchListTile(
              title: const Text('بلوتوث'),
              value: model.netState['bt'] == true,
              onChanged: (v) => model.setNet('bt', v),
            ),
            if (model.sims.isNotEmpty)
              ListTile(
                title: const Text('سیم‌کارت اینترنت'),
                trailing: DropdownButton<int>(
                  value: _currentSub(model),
                  hint: const Text('انتخاب سیم‌کارت'),
                  items: [
                    for (final sim in model.sims)
                      DropdownMenuItem<int>(
                        value: (sim['sub'] as num?)?.toInt(),
                        child: Text(sim['name']?.toString() ?? 'سیم‌کارت'),
                      ),
                  ],
                  onChanged: (sub) {
                    if (sub != null) {
                      model.setNet('dataSub', true, sub: sub);
                    }
                  },
                ),
              ),
            ListTile(
              title: const Text('نوع شبکه'),
              trailing: DropdownButton<String>(
                value: _currentRat(model),
                hint: const Text('انتخاب شبکه'),
                items: const [
                  DropdownMenuItem(value: '2G', child: Text('2G')),
                  DropdownMenuItem(value: '3G', child: Text('3G')),
                  DropdownMenuItem(value: '4G', child: Text('4G')),
                  DropdownMenuItem(value: '5G', child: Text('5G')),
                ],
                onChanged: (mode) {
                  if (mode != null) {
                    model.setNet('rat', true,
                        slot: model.defaultSlot, mode: mode);
                  }
                },
              ),
            ),
            SwitchListTile(
              title: const Text('اشتراک VPN'),
              subtitle:
                  const Text('به‌زودی — پروکسی اشتراک هنوز پیاده نشده است'),
              value: model.netState['share'] == true,
              // Disabled until the Share-VPN proxy exists (finding 11:
              // the Hub refuses `share` requests for the same reason).
              onChanged: null,
            ),
          ],
        ),
      ),
    );
  }
}

/// The SIM currently carrying mobile data, for the dataSub dropdown:
/// the last chosen sub, else the default SIM — only when it is one of
/// the known SIMs, otherwise the dropdown shows its hint.
int? _currentSub(AppModel model) {
  final sub = model.netState['dataSub'];
  final current = sub is num ? sub.toInt() : null;
  bool known(int? s) =>
      model.sims.any((sim) => (sim['sub'] as num?)?.toInt() == s);
  if (current != null && known(current)) return current;
  final fallback = (model.status?['defaultSub'] as num?)?.toInt();
  if (fallback != null && known(fallback)) return fallback;
  return null;
}

/// The current radio mode, for the rat dropdown.
String? _currentRat(AppModel model) {
  const modes = {'2G', '3G', '4G', '5G'};
  final mode = model.netState['rat'];
  return mode is String && modes.contains(mode) ? mode : null;
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('اطلاعات اتصال',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _InfoRow(label: 'نسخه برنامه', value: '۱٫۰٫۰'),
            _InfoRow(
                label: 'رمزگذاری',
                value: 'P-256 + AES-256-GCM'),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label,
              style: Theme.of(context).textTheme.bodySmall),
          const Spacer(),
          Text(value,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _PairingCard extends StatelessWidget {
  const _PairingCard({required this.model, required this.codeController});

  final AppModel model;
  final TextEditingController codeController;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('جفت‌سازی',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'برای جفت کردن، کد زیر را در گوشی اندروید اسکن کنید، یا کد گوشی اندروید را اینجا وارد کنید.',
            ),
            const SizedBox(height: 12),
            if (model.ownPairingCode != null) ...[
              Center(
                child: PairingQrCode(code: model.ownPairingCode!),
              ),
              const SizedBox(height: 8),
              SelectableText(
                model.ownPairingCode!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              // Share the pairing string as text (finding N2): the
              // iPhone user pastes it instead of scanning the QR.
              OutlinedButton.icon(
                key: const ValueKey('pairing-share'),
                icon: const Icon(Icons.share),
                label: const Text('اشتراک‌گذاری کد به‌صورت متن'),
                onPressed: () => model.sharePairingCode(),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              key: const ValueKey('pairing-code-input'),
              controller: codeController,
              decoration: const InputDecoration(
                hintText: 'tether1:…',
                labelText: 'کد جفت‌سازی گوشی اندروید',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              textDirection: TextDirection.ltr,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  key: const ValueKey('pairing-submit'),
                  onPressed: () {
                    final code = PairingCode.parse(codeController.text);
                    if (code == null) {
                      model.fail('کد جفت‌سازی معتبر نیست');
                      return;
                    }
                    model.pair(code);
                    model.flash('جفت‌سازی انجام شد');
                  },
                  child: const Text('جفت کردن'),
                ),
                const SizedBox(width: 8),
                // Camera QR scanner (finding N2): scan the Android
                // phone's QR instead of pasting the string.
                OutlinedButton.icon(
                  key: const ValueKey('pairing-scan'),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('اسکن کد QR'),
                  onPressed: () async {
                    final code = await Navigator.of(context)
                        .push<String>(
                      MaterialPageRoute(
                        builder: (_) => QrScannerView(
                          onCode: (value) =>
                              Navigator.of(context).pop(value),
                          scannerBuilder: model.qrScannerBuilder,
                        ),
                      ),
                    );
                    if (code == null) return;
                    final parsed = PairingCode.parse(code);
                    if (parsed == null) {
                      model.fail('کد جفت‌سازی معتبر نیست');
                      return;
                    }
                    model.pair(parsed);
                    model.flash('جفت‌سازی انجام شد');
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Crash-report card: the app writes its own log file
/// (`sim_bridge.log`), so a crash can be diagnosed without logcat.
/// Shows the file path + size and the last lines, and lets the user
/// share the file (to send to us), copy its path, or clear it.
class _LogCard extends StatefulWidget {
  const _LogCard();

  @override
  State<_LogCard> createState() => _LogCardState();
}

class _LogCardState extends State<_LogCard> {
  List<String> _tail = const [];
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _tail = AppLogger.tail(lines: 5);
    });
  }

  @override
  Widget build(BuildContext context) {
    final path = AppLogger.path;
    final sizeKb = (AppLogger.sizeBytes / 1024).toStringAsFixed(1);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('گزارش خطا',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'اگر برنامه کرش کرد یا مشکلی داشت، این فایل را برای ما بفرستید تا علت را پیدا کنیم. '
              'یک کپی از لاگ همیشه در پوشه‌ی Downloads با نام sim_bridge.log هم گذاشته می‌شود، '
              'پس حتی اگر برنامه باز نشد، از Files ← Downloads می‌توانید آن را پیدا و بفرستید.',
            ),
            const SizedBox(height: 8),
            if (path == null) ...[
              const Text('لاگ هنوز آماده نیست.'),
            ] else ...[
              SelectableText(
                path,
                style: Theme.of(context).textTheme.bodySmall,
                textDirection: TextDirection.ltr,
              ),
              Text(
                'حجم: $sizeKb کیلوبایت',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_tail.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: SelectableText(
                    _tail.join('\n'),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(fontFamily: 'monospace'),
                    textDirection: TextDirection.ltr,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('log-share'),
                    icon: const Icon(Icons.share),
                    label: const Text('اشتراک‌گذاری لاگ'),
                    onPressed: _sharing
                        ? null
                        : () async {
                            setState(() => _sharing = true);
                            try {
                              await SharePlus.instance.share(
                                ShareParams(
                                  files: [XFile(path)],
                                  subject: 'sim_bridge log',
                                ),
                              );
                            } catch (_) {
                              // The share sheet failing must not
                              // crash the Link tab.
                            } finally {
                              if (mounted) {
                                setState(() => _sharing = false);
                              }
                            }
                          },
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('log-mirror-downloads'),
                    icon: const Icon(Icons.download),
                    label: const Text('کپی لاگ در Downloads'),
                    onPressed: _sharing
                        ? null
                        : () async {
                            final ok =
                                await AppLogger.mirrorToDownloads(force: true);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(ok
                                      ? 'لاگ در Downloads کپی شد: sim_bridge.log'
                                      : 'کپی لاگ ممکن نشد؛ لاگ هنوز آماده نیست.'),
                                ),
                              );
                            }
                            _refresh();
                          },
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('log-copy-path'),
                    icon: const Icon(Icons.copy),
                    label: const Text('کپی مسیر'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: path));
                    },
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('log-clear'),
                    icon: const Icon(Icons.delete),
                    label: const Text('پاک کردن لاگ'),
                    onPressed: () async {
                      await AppLogger.clear();
                      _refresh();
                    },
                  ),
                  IconButton(
                    key: const ValueKey('log-refresh'),
                    icon: const Icon(Icons.refresh),
                    tooltip: 'تازه‌سازی',
                    onPressed: _refresh,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DemoCard extends StatelessWidget {
  const _DemoCard({required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('نمایشی',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              'داده‌ها نمونه هستند؛ برای بررسی رابط کاربری بدون اتصال به گوشی.',
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('demo-incoming-call'),
              icon: const Icon(Icons.call_received),
              label: const Text('تماس ورودی آزمایشی'),
              onPressed: () => model.simulateIncomingCall(
                number: '+989121234567',
                name: 'سارا احمدی',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The real pairing QR code: scans to the `tether1:…` payload
/// ([PairingCode.encode]) the Android phone shows for pairing.
/// Rendered by `qr_flutter` — the earlier 21×21 placeholder grid
/// could not be scanned (finding 6).
class PairingQrCode extends StatelessWidget {
  const PairingQrCode({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.white,
      child: QrImageView(
        data: code,
        version: QrVersions.auto,
        size: 189,
        backgroundColor: Colors.white,
      ),
    );
  }
}

/// Camera QR scanner (finding N2): the iPhone scans the Android
/// phone's pairing QR instead of pasting the `tether1:…` string.
/// Calls [onCode] once with the first non-empty barcode, then the
/// caller pops the route with the value.
class QrScannerView extends StatefulWidget {
  const QrScannerView({
    super.key,
    required this.onCode,
    this.scannerBuilder,
  });

  /// Called once with the scanned `tether1:…` string.
  final ValueChanged<String> onCode;

  /// Builds the camera scanner; tests inject a fake that calls
  /// [onCode] with a canned string. Defaults to [MobileScanner].
  final Widget Function(ValueChanged<String> onCode)? scannerBuilder;

  @override
  State<QrScannerView> createState() => _QrScannerViewState();
}

class _QrScannerViewState extends State<QrScannerView> {
  bool _handled = false;

  void _onCode(String value) {
    if (_handled || value.isEmpty) return;
    _handled = true;
    widget.onCode(value);
  }

  @override
  Widget build(BuildContext context) {
    final builder = widget.scannerBuilder ?? _defaultScanner;
    return Scaffold(
      appBar: AppBar(
        title: const Text('اسکن کد QR'),
      ),
      body: Stack(
        children: [
          builder(_onCode),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'کد QR روی گوشی اندروید را جلوی دوربین بگیرید',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _defaultScanner(ValueChanged<String> onCode) {
    return MobileScanner(
      onDetect: (capture) {
        for (final barcode in capture.barcodes) {
          final raw = barcode.rawValue;
          if (raw != null && raw.isNotEmpty) {
            onCode(raw);
            return;
          }
        }
      },
    );
  }
}

/// Bark setup (finding N1, iOS only): the device key the Android
/// side pushes wake-up alerts to when the link is down. Nothing
/// ever wrote the key before — this card is the entry path: the
/// user copies the key from the Bark app, pastes it here, and the
/// next `sync` carries it.
class _BarkCard extends StatefulWidget {
  const _BarkCard({required this.model});

  final AppModel model;

  @override
  State<_BarkCard> createState() => _BarkCardState();
}

class _BarkCardState extends State<_BarkCard> {
  late final TextEditingController _keyController =
      TextEditingController(text: widget.model.barkKey ?? '');

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('بیدار کردن آیفون از راه دور (Bark)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'وقتی لینک قطع است، گوشی اندروید با Bark به این آیفون هشدار می‌دهد تا زنگ بخورد. کلید دستگاه را از برنامه Bark کپی کنید و اینجا وارد کنید.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('bark-key-input'),
              controller: _keyController,
              decoration: const InputDecoration(
                hintText: 'کلید دستگاه Bark',
                labelText: 'کلید دستگاه',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              textDirection: TextDirection.ltr,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  key: const ValueKey('bark-key-save'),
                  onPressed: () async {
                    await model.saveBarkKey(_keyController.text);
                    if (context.mounted && _keyController.text.trim().isNotEmpty) {
                      model.flash('کلید Bark ذخیره شد');
                    }
                  },
                  child: const Text('ذخیره کلید'),
                ),
                if (model.hasBarkKey) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('bark-key-copy'),
                    icon: const Icon(Icons.copy),
                    label: const Text('کپی کلید من'),
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: model.barkKey!));
                      model.flash('کلید کپی شد');
                    },
                  ),
                ],
              ],
            ),
            if (model.hasBarkKey) ...[
              const SizedBox(height: 8),
              SelectableText(
                model.barkKey!,
                style: Theme.of(context).textTheme.bodySmall,
                textDirection: TextDirection.ltr,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'راهنما: برنامه Bark را باز کنید ← کلید دستگاه را کپی کنید ← اینجا بچسبانید و ذخیره کنید.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// WebRTC settings (finding N3): the Cloudflare Worker signalling
/// URL and the TURN credentials. The URL is saved in shared
/// preferences; the credentials in secure storage. TURN credentials
/// last 24 hours, so the card also fetches fresh ones from the
/// Cloudflare API — the API token is only used for that one call
/// and is never stored.
class _WebrtcSettingsCard extends StatefulWidget {
  const _WebrtcSettingsCard({required this.model});

  final AppModel model;

  @override
  State<_WebrtcSettingsCard> createState() => _WebrtcSettingsCardState();
}

class _WebrtcSettingsCardState extends State<_WebrtcSettingsCard> {
  late final TextEditingController _urlController =
      TextEditingController(text: WebrtcSettings.signallingUrl);
  late final TextEditingController _turnUserController =
      TextEditingController(text: WebrtcSettings.turnUsername ?? '');
  late final TextEditingController _turnCredController =
      TextEditingController(text: WebrtcSettings.turnCredential ?? '');
  final TextEditingController _keyIdController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  bool _fetching = false;

  @override
  void dispose() {
    _urlController.dispose();
    _turnUserController.dispose();
    _turnCredController.dispose();
    _keyIdController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final configured = WebrtcSettings.isConfigured;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('اتصال از راه دور (WebRTC)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              configured
                  ? 'اتصال از راه دور پیکربندی شده است.'
                  : 'هنوز پیکربندی نشده است: آدرس سرور سیگنالینگ (Cloudflare Worker) را وارد کنید.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('webrtc-url-input'),
              controller: _urlController,
              decoration: const InputDecoration(
                hintText: 'https://sim-bridge-signal.<sub>.workers.dev',
                labelText: 'آدرس سرور سیگنالینگ',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              textDirection: TextDirection.ltr,
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('webrtc-url-save'),
              onPressed: () async {
                await model.saveSignallingUrl(_urlController.text);
                if (context.mounted) {
                  model.flash('آدرس سیگنالینگ ذخیره شد');
                }
              },
              child: const Text('ذخیره آدرس'),
            ),
            const SizedBox(height: 16),
            Text('اعتبار TURN کلادفلر (۲۴ ساعته)',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('webrtc-turn-user-input'),
              controller: _turnUserController,
              decoration: const InputDecoration(
                labelText: 'نام کاربری TURN',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              textDirection: TextDirection.ltr,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('webrtc-turn-credential-input'),
              controller: _turnCredController,
              decoration: const InputDecoration(
                labelText: 'رمز TURN',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              textDirection: TextDirection.ltr,
              obscureText: true,
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('webrtc-turn-save'),
              onPressed: () async {
                await model.saveTurnCredentials(
                  _turnUserController.text,
                  _turnCredController.text,
                );
                if (context.mounted) {
                  model.flash('اعتبار TURN ذخیره شد');
                }
              },
              child: const Text('ذخیره اعتبار TURN'),
            ),
            const SizedBox(height: 16),
            Text('دریافت اعتبار تازه از Cloudflare',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('webrtc-turn-keyid-input'),
              controller: _keyIdController,
              decoration: const InputDecoration(
                labelText: 'شناسه کلید TURN',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              textDirection: TextDirection.ltr,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('webrtc-turn-token-input'),
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'توکن API کلادفلر',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              textDirection: TextDirection.ltr,
              obscureText: true,
            ),
            const SizedBox(height: 4),
            Text(
              'توکن API فقط برای همین درخواست استفاده می‌شود و ذخیره نمی‌شود.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey('webrtc-turn-fetch'),
              icon: const Icon(Icons.refresh),
              label: const Text('دریافت اعتبار تازه TURN'),
              onPressed: _fetching
                  ? null
                  : () async {
                      if (_keyIdController.text.trim().isEmpty ||
                          _tokenController.text.trim().isEmpty) {
                        model.fail('شناسه کلید و توکن API را وارد کنید');
                        return;
                      }
                      setState(() => _fetching = true);
                      try {
                        await model.fetchTurnCredentials(
                          apiToken: _tokenController.text,
                          keyId: _keyIdController.text,
                        );
                        _turnUserController.text =
                            WebrtcSettings.turnUsername ?? '';
                        _turnCredController.text =
                            WebrtcSettings.turnCredential ?? '';
                        if (context.mounted) {
                          model.flash('اعتبار TURN تازه دریافت شد');
                        }
                      } catch (e) {
                        model.fail('دریافت اعتبار TURN ناموفق بود: $e');
                      } finally {
                        if (mounted) setState(() => _fetching = false);
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }
}
