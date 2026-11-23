/// [HubData] over the platform channels (finding 3): the Android
/// phone's SMS provider, dialer, and call-audio helper, per
/// `NATIVE_CHANNELS.md`.
///
/// Read paths go to the channel that owns the data: SMS, contacts
/// and lists live in [SmsBridge]; call actions and dialing in
/// [TelecomBridge]; network switches and the self-test in
/// [CallAudioBridge] (the shell helper).
///
/// One wrinkle: [HubData.contactsVersion] is synchronous, but the
/// channel's version is async. The version is cached and refreshed
/// at service start and after every contact mutation; it starts as
/// `''`, which forces a full contacts batch on the first sync (the
/// client holds nothing then, so that is the correct answer).
library;

import 'dart:async';

import '../protocol/messages.dart';
import 'channels.dart';
import 'hub.dart';

class ChannelHubData implements HubData {
  ChannelHubData({
    required this.sms,
    required this.telecom,
    required this.audio,
    this.onUnpair,
  });

  final SmsBridge sms;
  final TelecomBridge telecom;
  final CallAudioBridge audio;

  /// Called when a client unpairs, with the central's static key,
  /// so the caller can forget it (KeyStore).
  final void Function(List<int> peerKey)? onUnpair;

  String _contactsVersion = '';

  @override
  Future<List<Sms>> smsSince(int sinceId) => sms.smsSince(sinceId);

  @override
  Future<List<CallEntry>> callsSince(int sinceId) =>
      sms.callsSince(sinceId);

  @override
  Future<List<Contact>> contactsAll() => sms.contactsAll();

  @override
  String contactsVersion() => _contactsVersion;

  /// Refreshes the cached contacts version from the channel.
  Future<void> refreshContactsVersion() async {
    _contactsVersion = await sms.contactsVersion();
  }

  @override
  Future<List<int>> smsAllIds() => sms.smsAllIds();

  @override
  Future<List<int>> callAllIds() => sms.callAllIds();

  @override
  Future<List<int>?> unreadSmsIds() => sms.unreadSmsIds();

  @override
  Future<Map<String, dynamic>> statusJson() => sms.statusJson();

  @override
  Future<String?> sendSms({
    required String to,
    required String body,
    int? sub,
    required int localId,
    bool dry = false,
  }) async {
    // A dry-run session never performs a real send.
    if (dry) return null;
    final result = await sms.sendSms(
      to: to,
      body: body,
      sub: sub,
      localId: localId,
    );
    if (result['ok'] as bool? ?? false) return null;
    return result['err'] as String? ?? 'send failed';
  }

  @override
  Future<int> markSmsRead(int thread, int upTo) =>
      sms.markRead(thread, upTo);

  @override
  Future<List<int>?> deleteSms(List<int> ids, int? thread) =>
      sms.deleteMessages(ids, thread: thread);

  @override
  Future<int> deleteCalls(List<int>? ids) => sms.deleteCalls(ids: ids);

  @override
  Future<int> setContactStarred(int id, bool on) async {
    final rows = await sms.setContactStarred(id, on);
    unawaited(refreshContactsVersion());
    return rows;
  }

  @override
  Future<int> addContact(
      String name, List<Phone> phones, List<String> emails) async {
    final id = await sms.addContact(name, phones, emails);
    unawaited(refreshContactsVersion());
    return id;
  }

  @override
  Future<String?> updateContact(
      int id, String name, List<Phone> phones, List<String> emails) async {
    final result = await sms.updateContact(id, name, phones, emails);
    unawaited(refreshContactsVersion());
    if (result['ok'] as bool? ?? false) return null;
    return result['err'] as String? ?? 'update failed';
  }

  @override
  Future<Map<String, dynamic>> listsJson() => sms.listsJson();

  @override
  Future<Map<String, dynamic>> setLists(
    String what, {
    String? num,
    int? thread,
    required bool on,
  }) async {
    final lists = await sms.setLists(
      what,
      num: num,
      thread: thread,
      on: on,
    );
    // The screening service enforces the block list: keep it in
    // sync whenever the list changes.
    final blocked = lists['blocked'];
    if (blocked is List) {
      unawaited(telecom.setBlockedNumbers(
        blocked.map((e) => e.toString()).toList(),
      ));
    }
    return lists;
  }

  @override
  Future<void> answerCall(String cid) => telecom.answerCall(cid);

  @override
  Future<void> rejectCall(String cid) => telecom.rejectCall(cid);

  @override
  Future<void> endCall(String cid) => telecom.endCall(cid);

  @override
  Future<void> holdCall(String cid, bool on) => telecom.holdCall(cid, on);

  @override
  Future<String?> dial(String num, int? sub) async {
    final result = await telecom.dial(num, sub: sub);
    if (result['ok'] as bool? ?? false) return null;
    return result['err'] as String? ?? 'dial failed';
  }

  @override
  Future<void> dtmf(String cid, String digit) => telecom.dtmf(cid, digit);

  @override
  Future<Map<String, dynamic>?> netControl({
    String? what,
    bool on = false,
    int? sub,
    int? slot,
    String? mode,
  }) =>
      audio.netControl(what: what, on: on, sub: sub, slot: slot, mode: mode);

  @override
  Future<Map<String, dynamic>> selftest() => audio.selftest();

  @override
  void unpair(List<int> peerKey) {
    onUnpair?.call(peerKey);
  }
}
