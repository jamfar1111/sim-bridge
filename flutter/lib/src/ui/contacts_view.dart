/// Contacts tab: searchable list with favourites, tap for call /
/// message actions.
library;

import 'package:material_ui/material_ui.dart';

import '../protocol/protocol.dart';
import 'app.dart';
import 'app_model.dart';
import 'messages_view.dart';
import 'widgets.dart';

class ContactsView extends StatefulWidget {
  const ContactsView({super.key});

  @override
  State<ContactsView> createState() => _ContactsViewState();
}

class _ContactsViewState extends State<ContactsView> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final model = AppModelScope.of(context);
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final q = _query.trim();
        final contacts = model.contacts.where((c) {
          if (q.isEmpty) return true;
          final needle = q.toLowerCase();
          return c.name.toLowerCase().contains(needle) ||
              c.phones.any((p) => p.n.contains(q));
        }).toList();
        final favourites =
            contacts.where((c) => c.starred).toList();
        final others =
            contacts.where((c) => !c.starred).toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                key: const ValueKey('contacts-search'),
                decoration: const InputDecoration(
                  hintText: 'جستجوی مخاطب',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: model.refreshLocalData,
                child: contacts.isEmpty
                    ? const EmptyRefreshable(label: 'مخاطبی پیدا نشد')
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          if (favourites.isNotEmpty) ...[
                            const _SectionHeader('علاقه‌مندی‌ها'),
                            for (final c in favourites)
                              _ContactRow(contact: c, model: model),
                          ],
                          if (others.isNotEmpty) ...[
                            const _SectionHeader('همه مخاطبین'),
                            for (final c in others)
                              _ContactRow(contact: c, model: model),
                          ],
                        ],
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(
          start: 16, top: 8, bottom: 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.contact, required this.model});

  final Contact contact;
  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final phone =
        contact.phones.isEmpty ? '' : contact.phones.first.n;
    return ListTile(
      key: ValueKey('contact-${contact.id}'),
      leading: Avatar(name: contact.name, photo: contact.photo),
      title: Text(contact.name),
      subtitle: phone.isEmpty ? null : Text(phone),
      trailing: IconButton(
        key: ValueKey('star-${contact.id}'),
        icon: Icon(
          contact.starred ? Icons.star : Icons.star_border,
          color: contact.starred ? Colors.amber : null,
        ),
        tooltip: contact.starred ? 'حذف از علاقه‌مندی‌ها' : 'علاقه‌مندی',
        onPressed: () => model.toggleStar(contact),
      ),
      onTap: () => _showActions(context, contact, phone),
    );
  }

  void _showActions(
      BuildContext context, Contact contact, String phone) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Avatar(name: contact.name, photo: contact.photo),
              title: Text(contact.name),
              subtitle: phone.isEmpty ? null : Text(phone),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.call),
              title: const Text('تماس'),
              onTap: () {
                Navigator.of(context).pop();
                if (phone.isNotEmpty) model.dial(phone);
              },
            ),
            ListTile(
              leading: const Icon(Icons.message),
              title: const Text('پیامک'),
              onTap: () {
                Navigator.of(context).pop();
                model.selectTab(3);
                // Open the thread for this number if one exists.
                final thread = model.conversations
                    .where((c) =>
                        numberKey(c.address) == numberKey(phone))
                    .map((c) => c.thread)
                    .firstOrNull;
                if (thread != null) {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ThreadView(thread: thread),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
