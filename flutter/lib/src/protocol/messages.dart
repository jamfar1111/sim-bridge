/// Control message envelope and data models (protocol §5).
///
/// Envelope: `{"t": "<type>", "id": <int>?, "re": <int>?, "b": { ... }?}`.
/// `id` is set on requests that expect an answer; the answer carries `re`.
/// Unknown types are ignored. Times are Unix milliseconds. Phone numbers
/// are as stored on the Android phone.
library;

import 'dart:convert' show jsonDecode, jsonEncode, utf8;

import 'otp.dart';

/// A control message. The body [b] is a plain JSON map.
class Message {
  const Message(this.t, {this.b = const {}, this.id, this.re});

  final String t;
  final Map<String, dynamic> b;
  final int? id;
  final int? re;

  /// Serialises to UTF-8 JSON, keys in wire order: t, id, re, b.
  List<int> toJsonBytes() {
    final map = <String, dynamic>{'t': t};
    if (id != null) map['id'] = id;
    if (re != null) map['re'] = re;
    map['b'] = b;
    return utf8.encode(jsonEncode(map));
  }

  static Message parse(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('message is not a JSON object');
    }
    final body = decoded['b'];
    return Message(
      decoded['t'] as String,
      b: body is Map<String, dynamic> ? body : const {},
      id: decoded['id'] as int?,
      re: decoded['re'] as int?,
    );
  }

  @override
  String toString() => 'Message($t id=$id re=$re)';
}

/// Control message type names (protocol §5).
abstract final class MessageType {
  static const String ping = 'ping';
  static const String pong = 'pong';
  static const String status = 'status';
  static const String sync = 'sync';
  static const String smsBatch = 'sms.batch';
  static const String smsNew = 'sms.new';
  static const String smsSend = 'sms.send';
  static const String smsRead = 'sms.read';
  static const String smsUnread = 'sms.unread';
  static const String smsResult = 'sms.result';
  static const String contactsBatch = 'contacts.batch';
  static const String contactAdd = 'contact.add';
  static const String contactUpdate = 'contact.update';
  static const String contactStar = 'contact.star';
  static const String contactResult = 'contact.result';
  static const String callsBatch = 'calls.batch';
  static const String callState = 'call.state';
  static const String callList = 'call.list';
  static const String callAnswer = 'call.answer';
  static const String callReject = 'call.reject';
  static const String callEnd = 'call.end';
  static const String callHold = 'call.hold';
  static const String callMute = 'call.mute';
  static const String callDtmf = 'call.dtmf';
  static const String callDial = 'call.dial';
  static const String callDialed = 'call.dialed';
  static const String callTake = 'call.take';
  static const String audioStart = 'audio.start';
  static const String audioStop = 'audio.stop';
  static const String selftest = 'selftest';
  static const String selftestResult = 'selftest.result';
  static const String netGet = 'net.get';
  static const String netSet = 'net.set';
  static const String netState = 'net.state';
  static const String smsDelete = 'sms.delete';
  static const String smsDeleted = 'sms.deleted';
  static const String callsDelete = 'calls.delete';
  static const String callsDeleted = 'calls.deleted';
  static const String listsSet = 'lists.set';
  static const String lists = 'lists';
  static const String syncIds = 'sync.ids';
  static const String unpair = 'unpair';
  static const String error = 'error';
}

/// An SMS row.
/// `box`: 1 inbox, 2 sent, 3 draft, 4 outbox, 5 failed, 6 queued.
class Sms {
  const Sms({
    required this.id,
    required this.thread,
    required this.addr,
    required this.body,
    required this.date,
    required this.box,
    required this.read,
    this.sub,
  });

  final int id;
  final int thread;
  final String addr;
  final String body;
  final int date;
  final int box;
  final bool read;
  final int? sub;

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'id': id,
      'thread': thread,
      'addr': addr,
      'body': body,
      'date': date,
      'box': box,
      'read': read,
    };
    if (sub != null) map['sub'] = sub;
    return map;
  }

  factory Sms.fromJson(Map<String, dynamic> json) => Sms(
        id: json['id'] as int,
        thread: json['thread'] as int,
        addr: json['addr'] as String,
        body: json['body'] as String,
        date: json['date'] as int,
        box: json['box'] as int,
        read: json['read'] as bool,
        sub: json['sub'] as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is Sms &&
      other.id == id &&
      other.thread == thread &&
      other.addr == addr &&
      other.body == body &&
      other.date == date &&
      other.box == box &&
      other.read == read &&
      other.sub == sub;

  @override
  int get hashCode =>
      Object.hash(id, thread, addr, body, date, box, read, sub);
}

class Phone {
  const Phone(this.n, this.type, [this.label]);

  final String n;
  final String type;
  final String? label;

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'n': n, 'type': type};
    if (label != null) map['label'] = label;
    return map;
  }

  factory Phone.fromJson(Map<String, dynamic> json) => Phone(
        json['n'] as String,
        json['type'] as String,
        json['label'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is Phone &&
      other.n == n &&
      other.type == type &&
      other.label == label;

  @override
  int get hashCode => Object.hash(n, type, label);
}

class Contact {
  const Contact({
    required this.id,
    required this.name,
    required this.phones,
    required this.emails,
    this.photo,
    required this.starred,
  });

  final int id;
  final String name;
  final List<Phone> phones;
  final List<String> emails;

  /// Base64 JPEG, at most 96 px.
  final String? photo;
  final bool starred;

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'id': id,
      'name': name,
      'phones': phones.map((p) => p.toJson()).toList(),
      'emails': emails,
      'starred': starred,
    };
    if (photo != null) map['photo'] = photo;
    return map;
  }

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        id: json['id'] as int,
        name: json['name'] as String,
        phones: (json['phones'] as List)
            .map((p) => Phone.fromJson(Map<String, dynamic>.from(p as Map)))
            .toList(),
        emails: (json['emails'] as List).cast<String>(),
        photo: json['photo'] as String?,
        starred: json['starred'] as bool,
      );

  /// Rough encoded size, used to keep pages under the record limit.
  int weight() => 80 +
      name.length * 2 +
      phones.length * 40 +
      emails.fold<int>(0, (sum, e) => sum + e.length + 4) +
      (photo?.length ?? 0);
}

/// A call-log row.
/// `type`: 1 incoming, 2 outgoing, 3 missed, 4 voicemail, 5 rejected,
/// 6 blocked.
class CallEntry {
  const CallEntry({
    required this.id,
    required this.num,
    this.name,
    required this.date,
    required this.dur,
    required this.type,
    this.sub,
  });

  final int id;
  final String num;
  final String? name;
  final int date;
  final int dur;
  final int type;
  final int? sub;

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'id': id,
      'num': num,
      'date': date,
      'dur': dur,
      'type': type,
    };
    if (name != null) map['name'] = name;
    if (sub != null) map['sub'] = sub;
    return map;
  }

  factory CallEntry.fromJson(Map<String, dynamic> json) => CallEntry(
        id: json['id'] as int,
        num: json['num'] as String,
        name: json['name'] as String?,
        date: json['date'] as int,
        dur: json['dur'] as int,
        type: json['type'] as int,
        sub: json['sub'] as int?,
      );
}

/// A live call.
/// `state`: "ringing" | "dialing" | "connecting" | "active" | "holding" |
/// "ended". `dir`: "in" | "out".
class CallInfo {
  const CallInfo({
    required this.cid,
    required this.num,
    this.name,
    required this.state,
    required this.dir,
    this.sub,
    this.since,
    this.cause,
    required this.hold,
    this.elsewhere,
    this.where,
  });

  final String cid;
  final String num;
  final String? name;
  final String state;
  final String dir;
  final int? sub;
  final int? since;
  final String? cause;

  /// Whether hold is supported for this call.
  final bool hold;

  /// True when the call's audio is on another client.
  final bool? elsewhere;

  /// Name of the client holding the audio (per receiver, see §5.1).
  final String? where;

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'cid': cid,
      'num': num,
      'state': state,
      'dir': dir,
      'hold': hold,
    };
    if (name != null) map['name'] = name;
    if (sub != null) map['sub'] = sub;
    if (since != null) map['since'] = since;
    if (cause != null) map['cause'] = cause;
    if (elsewhere != null) map['elsewhere'] = elsewhere;
    if (where != null) map['where'] = where;
    return map;
  }

  factory CallInfo.fromJson(Map<String, dynamic> json) => CallInfo(
        cid: json['cid'] as String,
        num: json['num'] as String,
        name: json['name'] as String?,
        state: json['state'] as String,
        dir: json['dir'] as String,
        sub: json['sub'] as int?,
        since: json['since'] as int?,
        cause: json['cause'] as String?,
        hold: json['hold'] as bool,
        elsewhere: json['elsewhere'] as bool?,
        where: json['where'] as String?,
      );
}

/// Splits items into pages whose summed weight stays under [maxWeight].
List<List<T>> paginate<T>(
    List<T> items, int maxWeight, int Function(T) weight) {
  final pages = <List<T>>[];
  var current = <T>[];
  var w = 0;
  for (final item in items) {
    final itemWeight = weight(item);
    if (current.isNotEmpty && w + itemWeight > maxWeight) {
      pages.add(current);
      current = <T>[];
      w = 0;
    }
    current.add(item);
    w += itemWeight;
  }
  if (current.isNotEmpty || pages.isEmpty) pages.add(current);
  return pages;
}

/// Ids as inclusive ranges, `[[first, last], …]`, ascending: how "these
/// rows still exist" is sent on sync so a client can drop what was
/// deleted (SMS and call ids are mostly consecutive, so this stays small).
List<List<int>> idRanges(List<int> ids) {
  final out = <List<int>>[];
  var start = -1;
  var prev = -1;
  for (final id in (List<int>.of(ids)..sort())) {
    if (start < 0) {
      start = id;
      prev = id;
      continue;
    }
    if (id == prev) continue;
    if (id != prev + 1) {
      out.add([start, prev]);
      start = id;
    }
    prev = id;
  }
  if (start >= 0) out.add([start, prev]);
  return out;
}

/// Same key as the iOS `PhoneNumber.matchKey`: the last 9 digits
/// (Persian/Arabic digits included), so "+98912…" matches "0912…".
/// Delegates to [PhoneNumber.matchKey] — one implementation only.
String numberKey(String value) => PhoneNumber.matchKey(value);
