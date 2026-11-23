/// Messages tab: conversation list + thread view with a send box,
/// OTP auto-copy affordance and unread badges.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../protocol/protocol.dart';
import 'app.dart';
import 'app_model.dart';
import 'widgets.dart';

class MessagesView extends StatelessWidget {
  const MessagesView({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppModelScope.of(context);
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        // A deep link asked for a thread (`simbridge://sms?thread=…`):
        // push it once, after this frame. The request is consumed
        // synchronously so a rebuild before the frame runs cannot
        // push it twice.
        final pending = model.pendingThread;
        if (pending != null) {
          model.pendingThread = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ThreadView(thread: pending),
              ),
            );
          });
        }
        final conversations = model.conversations;
        return RefreshIndicator(
          onRefresh: model.refreshLocalData,
          child: conversations.isEmpty
              ? const EmptyRefreshable(label: 'پیامی نیست')
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: conversations.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c = conversations[i];
                    return _ConversationRow(conversation: c, model: model);
                  },
                ),
        );
      },
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({required this.conversation, required this.model});

  final Conversation conversation;
  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final display = model.displayName(conversation.address);
    return ListTile(
      key: ValueKey('conversation-${conversation.thread}'),
      leading: Avatar(name: display),
      title: Text(
        display,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        conversation.last.body,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            shortTime(conversation.last.date),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (conversation.unread > 0) ...[
            const SizedBox(height: 4),
            Badge(
              label: Text('${conversation.unread}'),
              backgroundColor: Colors.green,
              child: const SizedBox.shrink(),
            ),
          ],
        ],
      ),
      onTap: () {
        model.markThreadRead(conversation.thread);
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ThreadView(thread: conversation.thread),
          ),
        );
      },
    );
  }
}

/// One conversation: bubbles, OTP copy chips, send box.
class ThreadView extends StatefulWidget {
  const ThreadView({super.key, required this.thread});

  final int thread;

  @override
  State<ThreadView> createState() => _ThreadViewState();
}

class _ThreadViewState extends State<ThreadView> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final model = AppModelScope.of(context);
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final messages = model.messagesForThread(widget.thread);
        final first = messages.firstOrNull;
        final address = first?.addr ?? '';
        final title = model.displayName(address);
        _scrollToBottom();
        return Scaffold(
          appBar: AppBar(title: Text(title)),
          body: Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, i) {
                    final m = messages[i];
                    return _MessageBubble(message: m, model: model);
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('thread-input'),
                          controller: _controller,
                          decoration: const InputDecoration(
                            hintText: 'پیام…',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(model, address),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        key: const ValueKey('thread-send'),
                        icon: const Icon(Icons.send),
                        tooltip: 'ارسال',
                        onPressed: () => _send(model, address),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _send(AppModel model, String address) {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    model.sendSms(address, text, thread: widget.thread);
    _controller.clear();
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.model});

  final Sms message;
  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final outgoing = message.box != 1;
    final code = OtpExtractor.extract(message.body);
    final bubbleColor = outgoing
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message.body),
            const SizedBox(height: 2),
            Text(
              shortTime(message.date),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (code != null) ...[
              const SizedBox(height: 6),
              OutlinedButton.icon(
                key: ValueKey('otp-copy-$code'),
                icon: const Icon(Icons.copy, size: 16),
                label: Text('کپی کد $code'),
                onPressed: () async {
                  try {
                    await Clipboard.setData(ClipboardData(text: code));
                  } catch (_) {
                    // Clipboard is unavailable in some test hosts.
                  }
                  model.flash('کد کپی شد');
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
