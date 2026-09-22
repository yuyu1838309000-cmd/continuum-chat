/// 像素小家新结构模型（state_new.json，8089 static 直读）。
///
/// 与引擎内部结构一一对应：me/appUser/cat（人物）+ stocks 五区 +
/// rooms/room_traces/bed/details/notes/house/time。所有字段防御式解析，
/// 服务器缺字段/类型不符时回退默认值，不让整页崩溃。
library;

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : <String, dynamic>{};

List<dynamic> _list(Object? value) => value is List ? value : const [];

List<String> _stringList(Object? value) => [
  for (final e in _list(value))
    if (e is String && e.trim().isNotEmpty) e.trim(),
];

String _str(Object? value) => value is String ? value.trim() : '';

/// 全家状态（顶层 JSON）。
class PixelHome {
  final CharacterState me;
  final CharacterState appUser;
  final CharacterState cat;
  final Map<String, HomeRoom> rooms;
  final Map<String, List<String>> roomTraces;
  final BedState bed;
  final List<String> details;
  final List<HomeNote> notes;
  final Map<String, StockZone> stocks;
  final HouseState house;
  final String time;

  const PixelHome({
    required this.me,
    required this.appUser,
    required this.cat,
    required this.rooms,
    required this.roomTraces,
    required this.bed,
    required this.details,
    required this.notes,
    required this.stocks,
    required this.house,
    required this.time,
  });

  factory PixelHome.fromJson(Map<String, dynamic> json) => PixelHome(
    me: CharacterState.fromJson(_map(json['me'])),
    appUser: CharacterState.fromJson(_map(json['appUser'])),
    cat: CharacterState.fromJson(_map(json['cat'])),
    rooms: {
      for (final e in _map(json['rooms']).entries)
        e.key: HomeRoom.fromJson(_map(e.value)),
    },
    roomTraces: {
      for (final e in _map(json['room_traces']).entries)
        e.key: _stringList(e.value),
    },
    bed: BedState.fromJson(_map(json['bed'])),
    details: _stringList(json['details']),
    notes: [
      for (final e in _list(json['notes']))
        if (e is Map<String, dynamic>) HomeNote.fromJson(e),
    ],
    stocks: {
      for (final e in _map(json['stocks']).entries)
        e.key: StockZone.fromJson(_map(e.value)),
    },
    house: HouseState.fromJson(_map(json['house'])),
    time: _str(json['time']),
  );
}

/// 人物状态：房间 + 动作 + 情绪 + 想法。
class CharacterState {
  final String room;
  final String action;
  final String mood;
  final String think;

  const CharacterState({
    required this.room,
    required this.action,
    required this.mood,
    required this.think,
  });

  factory CharacterState.fromJson(Map<String, dynamic> json) => CharacterState(
    room: _str(json['room']),
    action: _str(json['action']),
    mood: _str(json['mood']),
    think: _str(json['think']),
  );
}

/// 房间：zones = [{n: 名称, i: 图标 emoji, d: 描述}]。
class HomeRoom {
  final List<HomeZone> zones;

  const HomeRoom({required this.zones});

  factory HomeRoom.fromJson(Map<String, dynamic> json) => HomeRoom(
    zones: [
      for (final e in _list(json['zones']))
        if (e is Map<String, dynamic>) HomeZone.fromJson(e),
    ],
  );
}

class HomeZone {
  final String name;
  final String icon;
  final String desc;

  const HomeZone({required this.name, required this.icon, required this.desc});

  factory HomeZone.fromJson(Map<String, dynamic> json) => HomeZone(
    name: _str(json['n']),
    icon: _str(json['i']),
    desc: _str(json['d']),
  );
}

/// 库存区（fridge/cabinet/pantry/teaTable/storage 五区）。
class StockZone {
  final List<StockItem> items;
  final String note;
  final bool aging;

  const StockZone({
    required this.items,
    required this.note,
    required this.aging,
  });

  factory StockZone.fromJson(Map<String, dynamic> json) => StockZone(
    items: [
      for (final e in _list(json['items']))
        if (e is Map<String, dynamic>) StockItem.fromJson(e),
    ],
    note: _str(json['note']),
    aging: json['aging'] == true,
  );
}

class StockItem {
  final String name;
  final String emoji;
  final num qty;
  final String boughtAt;
  final int keepDays;

  const StockItem({
    required this.name,
    required this.emoji,
    required this.qty,
    required this.boughtAt,
    required this.keepDays,
  });

  factory StockItem.fromJson(Map<String, dynamic> json) {
    final rawQty = json['qty'];
    return StockItem(
      name: _str(json['name']),
      emoji: _str(json['emoji']),
      qty: rawQty is num && rawQty > 0 ? rawQty : 1,
      boughtAt: _str(json['bought_at']),
      keepDays: json['keep_days'] is int ? json['keep_days'] as int : 0,
    );
  }

  /// 数量展示：整数不带小数点（2 -> "2"，0.5 -> "0.5"）。
  String get qtyLabel {
    final q = qty.toDouble();
    return q == q.roundToDouble() ? q.toInt().toString() : q.toString();
  }
}

/// 床铺状态。
class BedState {
  final bool made;
  final List<String> pillows;
  final String lastSlept;
  final String note;
  final List<String> extras;

  const BedState({
    required this.made,
    required this.pillows,
    required this.lastSlept,
    required this.note,
    required this.extras,
  });

  factory BedState.fromJson(Map<String, dynamic> json) => BedState(
    made: json['made'] == true,
    pillows: _stringList(json['pillows']),
    lastSlept: _str(json['last_slept']),
    note: _str(json['note']),
    extras: _stringList(json['extras']),
  );
}

/// 冰箱贴便签。
class HomeNote {
  final String who;
  final String text;
  final String time;

  const HomeNote({required this.who, required this.text, required this.time});

  factory HomeNote.fromJson(Map<String, dynamic> json) => HomeNote(
    who: _str(json['who']),
    text: _str(json['text']),
    time: _str(json['time']),
  );
}

/// 家的氛围：时段/天气/一句话。
class HouseState {
  final String time;
  final String weather;
  final String note;

  const HouseState({
    required this.time,
    required this.weather,
    required this.note,
  });

  factory HouseState.fromJson(Map<String, dynamic> json) => HouseState(
    time: _str(json['time']),
    weather: _str(json['weather']),
    note: _str(json['note']),
  );
}
