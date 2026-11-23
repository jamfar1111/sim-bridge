/// Keypad tab: dial pad with number display and a call button.
/// During a live call the same pad sends DTMF (see [CallView]).
library;

import 'package:material_ui/material_ui.dart';

import 'app.dart';

class KeypadView extends StatefulWidget {
  const KeypadView({super.key});

  @override
  State<KeypadView> createState() => _KeypadViewState();
}

class _KeypadViewState extends State<KeypadView> {
  String _number = '';

  @override
  Widget build(BuildContext context) {
    final model = AppModelScope.of(context);
    return Column(
      children: [
        const Spacer(),
        // Number display (left-to-right so "+" stays on the left).
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Expanded(
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    _number.isEmpty ? '' : _number,
                    key: const ValueKey('keypad-display'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('keypad-backspace'),
                icon: const Icon(Icons.backspace_outlined),
                tooltip: 'پاک کردن',
                onPressed: _number.isEmpty
                    ? null
                    : () => setState(() {
                          _number = _number.substring(0, _number.length - 1);
                        }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: _DialPad(
            keyPrefix: 'key',
            onDigit: (d) => setState(() => _number += d),
            // Long-press on 0 types "+" (international numbers).
            longPress: const {'0': '+'},
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: FloatingActionButton(
            key: const ValueKey('keypad-call'),
            onPressed: _number.isEmpty
                ? null
                : () {
                    model.dial(_number);
                    setState(() => _number = '');
                  },
            backgroundColor: Colors.green,
            tooltip: 'تماس',
            child: const Icon(Icons.call, color: Colors.white),
          ),
        ),
      ],
    );
  }
}

const List<(String, String)> _keys = [
  ('1', ''),
  ('2', 'ABC'),
  ('3', 'DEF'),
  ('4', 'GHI'),
  ('5', 'JKL'),
  ('6', 'MNO'),
  ('7', 'PQRS'),
  ('8', 'TUV'),
  ('9', 'WXYZ'),
  ('*', ''),
  ('0', '+'),
  ('#', ''),
];

class _KeyButton extends StatelessWidget {
  const _KeyButton({
    super.key,
    required this.digit,
    required this.letters,
    required this.onTap,
    this.onLongPress,
  });

  final String digit;
  final String letters;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                digit,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (letters.isNotEmpty)
                Text(
                  letters,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// DTMF pad shown inside the call screen: same keys, sends digits
/// through the model instead of appending to a number.
class DtmfPad extends StatelessWidget {
  const DtmfPad({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppModelScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: _DialPad(
        keyPrefix: 'dtmf',
        onDigit: model.sendDtmf,
      ),
    );
  }
}

/// Four rows of three keys, each a fixed height so the pad always
/// fits the screen (a GridView with aspect-ratio cells overflows on
/// short viewports and its lower keys stop receiving taps).
class _DialPad extends StatelessWidget {
  const _DialPad({
    required this.keyPrefix,
    required this.onDigit,
    this.longPress = const {},
  });

  final String keyPrefix;
  final void Function(String digit) onDigit;

  /// Long-press overrides: pressing and holding a key types the
  /// mapped digit instead (the keypad maps `0` → `+`). DTMF passes
  /// none — a `+` is not a DTMF tone.
  final Map<String, String> longPress;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < 4; r++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                for (var c = 0; c < 3; c++)
                  Expanded(
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 4),
                      child: SizedBox(
                        height: 60,
                        child: _KeyButton(
                          key: ValueKey(
                              '$keyPrefix-${_keys[r * 3 + c].$1}'),
                          digit: _keys[r * 3 + c].$1,
                          letters: _keys[r * 3 + c].$2,
                          onTap: () => onDigit(_keys[r * 3 + c].$1),
                          onLongPress:
                              longPress[_keys[r * 3 + c].$1] == null
                                  ? null
                                  : () => onDigit(
                                      longPress[_keys[r * 3 + c].$1]!),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
