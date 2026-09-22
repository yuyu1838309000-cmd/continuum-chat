import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/runtime_history_models.dart';
import '../services/runtime_history_repository.dart';
import '../utils/app_theme.dart';
import '../widgets/swipe_back.dart';
import 'day_page.dart';

enum _LoadStatus { idle, loading, ready, error }

enum _UsageView { daily, monthly, all }

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    super.key,
    this.repository,
    this.initialMonth,
    this.usageAnchor,
    this.timezoneOffsetMinutes,
  });
  final RuntimeHistoryRepository? repository;
  final DateTime? initialMonth;
  final DateTime? usageAnchor;
  final int? timezoneOffsetMinutes;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  static const _weekHeader = ['一', '二', '三', '四', '五', '六', '日'];
  late final RuntimeHistoryRepository _repository;
  late final bool _ownsRepository;
  late DateTime _month;
  DateTime? _selectedDate;
  var _calendarStatus = _LoadStatus.loading;
  var _monthUsageStatus = _LoadStatus.loading;
  var _recentStatus = _LoadStatus.loading;
  var _allStatus = _LoadStatus.idle;
  var _usageView = _UsageView.daily;
  var _daysWithMessages = <String>{};
  var _monthUsage = <String, HistoryTokenUsageDay>{};
  var _recentUsage = <String, HistoryTokenUsageDay>{};
  HistoryTokenUsageSnapshot? _allUsage;
  var _calendarCached = false;
  var _monthCached = false;
  var _recentCached = false;
  var _allCached = false;
  Object? _calendarError;
  Object? _monthError;
  Object? _recentError;
  Object? _allError;
  var _calendarRequest = 0;
  var _monthRequest = 0;

  DateTime get _anchor => widget.usageAnchor ?? DateTime.now();
  int get _offset =>
      widget.timezoneOffsetMinutes ?? _anchor.timeZoneOffset.inMinutes;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? RuntimeHistoryRepository();
    _ownsRepository = widget.repository == null;
    final initial = widget.initialMonth ?? _anchor;
    _month = DateTime(initial.year, initial.month);
    _selectedDate = _containsAnchor ? _dateOnly(_anchor) : null;
    _loadCalendar();
    _loadMonthUsage();
    _loadRecentUsage();
  }

  bool get _containsAnchor =>
      _month.year == _anchor.year && _month.month == _anchor.month;

  @override
  void dispose() {
    if (_ownsRepository) _repository.close();
    super.dispose();
  }

  Future<void> _loadCalendar() async {
    final request = ++_calendarRequest;
    final bounds = _monthBounds(_month);
    setState(() {
      _calendarStatus = _LoadStatus.loading;
      _daysWithMessages = {};
      _calendarCached = false;
      _calendarError = null;
    });
    try {
      final result = await _repository.calendar(
        start: bounds.start,
        end: bounds.end,
        timezoneOffsetMinutes: _offset,
      );
      if (!mounted || request != _calendarRequest) return;
      final dates = {
        for (final day in result.days)
          if (day.messageCount > 0) day.date,
      };
      setState(() {
        _daysWithMessages = dates;
        _calendarCached = result.fromCache;
        _calendarStatus = _LoadStatus.ready;
        if (!_containsAnchor && _selectedDate == null) {
          _selectedDate = dates.isEmpty
              ? null
              : _parseDate(dates.reduce((a, b) => a.compareTo(b) >= 0 ? a : b));
        }
      });
    } catch (error) {
      if (!mounted || request != _calendarRequest) return;
      setState(() {
        _calendarError = error;
        _calendarStatus = _LoadStatus.error;
      });
    }
  }

  Future<void> _loadMonthUsage() async {
    final request = ++_monthRequest;
    final bounds = _monthBounds(_month);
    setState(() {
      _monthUsageStatus = _LoadStatus.loading;
      _monthUsage = {};
      _monthCached = false;
      _monthError = null;
    });
    try {
      final result = await _repository.tokenUsage(
        start: bounds.start,
        end: bounds.end,
        timezoneOffsetMinutes: _offset,
      );
      if (!mounted || request != _monthRequest) return;
      setState(() {
        _monthUsage = {for (final day in result.days) day.date: day};
        _monthCached = result.fromCache;
        _monthUsageStatus = _LoadStatus.ready;
      });
    } catch (error) {
      if (!mounted || request != _monthRequest) return;
      setState(() {
        _monthError = error;
        _monthUsageStatus = _LoadStatus.error;
      });
    }
  }

  Future<void> _loadRecentUsage() async {
    final end = DateTime(_anchor.year, _anchor.month, _anchor.day + 1);
    final start = end.subtract(const Duration(days: 30));
    final bounds = _bounds(start, end);
    setState(() {
      _recentStatus = _LoadStatus.loading;
      _recentUsage = {};
      _recentCached = false;
      _recentError = null;
    });
    try {
      final result = await _repository.tokenUsage(
        start: bounds.start,
        end: bounds.end,
        timezoneOffsetMinutes: _offset,
      );
      if (!mounted) return;
      setState(() {
        _recentUsage = {for (final day in result.days) day.date: day};
        _recentCached = result.fromCache;
        _recentStatus = _LoadStatus.ready;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _recentError = error;
        _recentStatus = _LoadStatus.error;
      });
    }
  }

  Future<void> _loadAllUsage() async {
    setState(() {
      _allStatus = _LoadStatus.loading;
      _allUsage = null;
      _allCached = false;
      _allError = null;
    });
    try {
      int? cursor;
      int? revision;
      DateTime? earliest;
      var cached = false;
      final visited = <int?>{};
      while (true) {
        if (!visited.add(cursor)) throw StateError('Runtime 历史分页游标无效');
        final page = await _repository.conversations(
          beforeOrdinal: cursor,
          limit: 100,
          expectedRevision: revision,
        );
        revision ??= page.revision;
        cached = cached || page.fromCache;
        for (final conversation in page.items) {
          if (conversation.messageCount <= 0) continue;
          final openedAt = conversation.openedAt;
          if (openedAt == null) {
            throw StateError('无法确定完整 Runtime 统计范围：会话缺少 openedAt');
          }
          if (earliest == null || openedAt.isBefore(earliest)) {
            earliest = openedAt;
          }
        }
        if (!page.hasMore) break;
        cursor = page.nextBeforeOrdinal;
        if (cursor == null) throw StateError('Runtime 历史分页缺少下一页游标');
      }
      HistoryTokenUsageSnapshot result;
      if (earliest == null) {
        result = HistoryTokenUsageSnapshot(days: const [], fromCache: cached);
      } else {
        final local = earliest.toUtc().add(Duration(minutes: _offset));
        final start = DateTime(local.year, local.month, local.day);
        final end = DateTime(_anchor.year, _anchor.month, _anchor.day + 1);
        if (!start.isBefore(end)) throw StateError('Runtime 历史起点晚于当前统计日');
        final bounds = _bounds(start, end);
        result = await _repository.tokenUsage(
          start: bounds.start,
          end: bounds.end,
          timezoneOffsetMinutes: _offset,
        );
        cached = cached || result.fromCache;
      }
      if (!mounted) return;
      setState(() {
        _allUsage = result;
        _allCached = cached;
        _allStatus = _LoadStatus.ready;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _allError = error;
        _allStatus = _LoadStatus.error;
      });
    }
  }

  void _changeMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selectedDate = _containsAnchor ? _dateOnly(_anchor) : null;
    });
    _loadCalendar();
    _loadMonthUsage();
  }

  void _changeView(_UsageView view) {
    setState(() => _usageView = view);
    if (view == _UsageView.all && _allStatus == _LoadStatus.idle) {
      _loadAllUsage();
    }
  }

  void _openDay(DateTime date) {
    setState(() => _selectedDate = date);
    Navigator.push(
      context,
      SwipeBackRoute(
        builder: (_) => DayPage(
          date: date,
          repository: _repository,
          timezoneOffsetMinutes: widget.timezoneOffsetMinutes,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.bgColor,
    appBar: AppBar(
      toolbarHeight: 64,
      title: const Text('日历'),
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0.5,
    ),
    body: ListView(
      key: const ValueKey('calendar-scroll'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.md,
      ),
      children: [
        _MonthSwitcher(month: _month, onChange: _changeMonth),
        const SizedBox(height: AppSpacing.sm),
        const _WeekHeader(),
        const SizedBox(height: AppSpacing.sm),
        _calendar(),
        const SizedBox(height: AppSpacing.sm),
        _HeatLegend(showMessageMarker: _daysWithMessages.isNotEmpty),
        if (_calendarCached || _monthCached) ...[
          const SizedBox(height: AppSpacing.xs),
          const _OfflineLabel(),
        ],
        if (_monthUsageStatus == _LoadStatus.error) ...[
          const SizedBox(height: 4),
          _InlineError(error: _monthError, retry: _loadMonthUsage),
        ],
        const SizedBox(height: AppSpacing.sm),
        _recent(),
        const SizedBox(height: AppSpacing.sm),
        _UsagePicker(value: _usageView, onChanged: _changeView),
        const SizedBox(height: 10),
        _summary(),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '点日期查看这一天聊了什么',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: context.subTextColor,
            fontSize: 10,
          ),
        ),
      ],
    ),
  );

  Widget _calendar() => switch (_calendarStatus) {
    _LoadStatus.loading => const SizedBox(
      height: 204,
      child: Center(child: CircularProgressIndicator()),
    ),
    _LoadStatus.error => SizedBox(
      height: 204,
      child: _LoadError(error: _calendarError, retry: _loadCalendar),
    ),
    _ => _MonthGrid(
      month: _month,
      messages: _daysWithMessages,
      usage: _monthUsage,
      selected: _selectedDate,
      onTap: _openDay,
    ),
  };

  Widget _recent() {
    final end = DateTime(_anchor.year, _anchor.month, _anchor.day + 1);
    final start = end.subtract(const Duration(days: 30));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 24,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '近30天 Token 热力',
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              if (_recentCached)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: _OfflineLabel(compact: true),
                ),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    'Provider 实际返回',
                    maxLines: 1,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.subTextColor,
                      fontSize: 10,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        switch (_recentStatus) {
          _LoadStatus.loading => const SizedBox(
            height: 96,
            child: Center(child: CircularProgressIndicator()),
          ),
          _LoadStatus.error => SizedBox(
            height: 96,
            child: _LoadError(
              error: _recentError,
              retry: _loadRecentUsage,
              compact: true,
            ),
          ),
          _ => _RecentChart(start: start, usage: _recentUsage),
        },
      ],
    );
  }

  Widget _summary() => switch (_usageView) {
    _UsageView.daily => _dailySummary(),
    _UsageView.monthly => _monthSummary(),
    _UsageView.all => _allSummary(),
  };

  Widget _dailySummary() {
    if (_selectedDate == null) return const _SummaryEmpty('未选择日期');
    if (_monthUsageStatus == _LoadStatus.loading) {
      return const _SummaryLoading();
    }
    if (_monthUsageStatus == _LoadStatus.error) {
      return _SummaryError(_monthError, _loadMonthUsage);
    }
    final usage = _monthUsage[_dateKey(_selectedDate!)];
    return usage == null
        ? const _SummaryEmpty('当天没有可统计的 Provider usage')
        : _SummaryValues(
            key: const ValueKey('usage-daily'),
            input: usage.inputTokens,
            output: usage.outputTokens,
          );
  }

  Widget _monthSummary() {
    if (_monthUsageStatus == _LoadStatus.loading) {
      return const _SummaryLoading();
    }
    if (_monthUsageStatus == _LoadStatus.error) {
      return _SummaryError(_monthError, _loadMonthUsage);
    }
    return _SummaryValues.fromDays(
      key: ValueKey('usage-month-${_month.year}-${_two(_month.month)}'),
      days: _monthUsage.values,
      empty: '本月没有可统计的 Provider usage',
    );
  }

  Widget _allSummary() => switch (_allStatus) {
    _LoadStatus.idle || _LoadStatus.loading => const _SummaryLoading(),
    _LoadStatus.error => _SummaryError(_allError, _loadAllUsage),
    _ => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SummaryValues.fromDays(
          key: const ValueKey('usage-all'),
          days: _allUsage?.days ?? const [],
          empty: '现有历史没有可统计的 Provider usage',
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '现有可统计历史',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: context.subTextColor,
                fontSize: 10,
              ),
            ),
            if (_allCached) ...[
              const SizedBox(width: 8),
              const _OfflineLabel(compact: true),
            ],
          ],
        ),
      ],
    ),
  };

  ({DateTime start, DateTime end}) _monthBounds(DateTime month) => _bounds(
    DateTime(month.year, month.month),
    DateTime(month.year, month.month + 1),
  );
  ({DateTime start, DateTime end}) _bounds(DateTime start, DateTime end) {
    if (widget.timezoneOffsetMinutes == null) return (start: start, end: end);
    return (
      start: _utcBoundary(start, _offset),
      end: _utcBoundary(end, _offset),
    );
  }
}

class _MonthSwitcher extends StatelessWidget {
  const _MonthSwitcher({required this.month, required this.onChange});
  final DateTime month;
  final ValueChanged<int> onChange;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: Row(
      children: [
        IconButton(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
          icon: const Icon(LucideIcons.chevron_left, size: 20),
          tooltip: '上一月',
          onPressed: () => onChange(-1),
        ),
        Expanded(
          child: Text(
            '${month.year}年${month.month}月',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
          icon: const Icon(LucideIcons.chevron_right, size: 20),
          tooltip: '下一月',
          onPressed: () => onChange(1),
        ),
      ],
    ),
  );
}

class _WeekHeader extends StatelessWidget {
  const _WeekHeader();
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 24,
    child: Row(
      children: [
        for (final label in _CalendarPageState._weekHeader)
          Expanded(
            child: Center(
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: context.subTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.messages,
    required this.usage,
    required this.selected,
    required this.onTap,
  });
  final DateTime month;
  final Set<String> messages;
  final Map<String, HistoryTokenUsageDay> usage;
  final DateTime? selected;
  final ValueChanged<DateTime> onTap;
  @override
  Widget build(BuildContext context) {
    final leading = DateTime(month.year, month.month).weekday - 1;
    final count = DateTime(month.year, month.month + 1, 0).day;
    final items = leading + count;
    final rows = (items / 7).ceil();
    final max = usage.values.fold<int>(
      0,
      (value, day) => math.max(value, day.totalTokens),
    );
    return SizedBox(
      height: rows * 36 + math.max(0, rows - 1) * 6,
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 7,
          mainAxisExtent: 36,
          mainAxisSpacing: 6,
        ),
        itemCount: items,
        itemBuilder: (context, index) {
          if (index < leading) return const SizedBox.shrink();
          final date = DateTime(month.year, month.month, index - leading + 1);
          final key = _dateKey(date);
          return _DayCell(
            date: date,
            usage: usage[key],
            max: max,
            hasMessages: messages.contains(key),
            selected: selected != null && _sameDay(selected!, date),
            onTap: () => onTap(date),
          );
        },
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.usage,
    required this.max,
    required this.hasMessages,
    required this.selected,
    required this.onTap,
  });
  final DateTime date;
  final HistoryTokenUsageDay? usage;
  final int max;
  final bool hasMessages;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final alpha = usage == null
        ? 0.0
        : 0.10 + (max == 0 ? 0 : usage!.totalTokens / max) * 0.28;
    final background = usage != null
        ? context.accentColor.withValues(alpha: alpha)
        : hasMessages
        ? context.fieldColor
        : Colors.transparent;
    final semantics = usage != null
        ? '${_format(usage!.totalTokens)} Token，Provider 已返回'
        : hasMessages
        ? '有消息，无 Provider usage'
        : '无消息';
    final key = _dateKey(date);
    return Semantics(
      button: true,
      selected: selected,
      label: '${date.month}月${date.day}日，$semantics',
      child: InkWell(
        key: ValueKey('calendar-day-$key'),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        onTap: onTap,
        child: Center(
          child: SizedBox(
            width: 34,
            height: 30,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(AppRadius.xs),
                border: selected
                    ? Border.all(color: context.accentColor, width: 1.2)
                    : null,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(
                    '${date.day}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: context.textColor,
                    ),
                  ),
                  Positioned(
                    bottom: 2,
                    child: SizedBox(
                      key: ValueKey('calendar-message-dot-$key'),
                      width: 4,
                      height: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: hasMessages && usage == null
                              ? context.subTextColor.withValues(alpha: 0.55)
                              : Colors.transparent,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeatLegend extends StatelessWidget {
  const _HeatLegend({required this.showMessageMarker});
  final bool showMessageMarker;
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: context.subTextColor,
      fontSize: 10,
      fontWeight: FontWeight.w400,
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 4,
      children: [
        Text('Token 热力', style: style),
        for (final alpha in const [0.10, 0.18, 0.28, 0.38])
          Container(
            width: 14,
            height: 8,
            decoration: BoxDecoration(
              color: context.accentColor.withValues(alpha: alpha),
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
          ),
        Text('低', style: style),
        Text('高', style: style),
        if (showMessageMarker) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: context.subTextColor.withValues(alpha: 0.55),
            ),
          ),
          Text('有消息但缺 usage', style: style),
        ],
      ],
    );
  }
}

class _RecentChart extends StatelessWidget {
  const _RecentChart({required this.start, required this.usage});
  final DateTime start;
  final Map<String, HistoryTokenUsageDay> usage;
  @override
  Widget build(BuildContext context) {
    final dates = [for (var i = 0; i < 30; i++) start.add(Duration(days: i))];
    final max = usage.values.fold<int>(
      0,
      (value, day) => math.max(value, day.totalTokens),
    );
    return Column(
      children: [
        SizedBox(
          height: 72,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final date in dates)
                Expanded(
                  child: _RecentBar(
                    date: date,
                    usage: usage[_dateKey(date)],
                    max: max,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          height: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final i in const [0, 7, 14, 21, 29])
                Text(
                  '${dates[i].month}月${dates[i].day}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: context.subTextColor,
                    fontSize: 9,
                    fontWeight: FontWeight.w400,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RecentBar extends StatelessWidget {
  const _RecentBar({
    required this.date,
    required this.usage,
    required this.max,
  });
  final DateTime date;
  final HistoryTokenUsageDay? usage;
  final int max;
  @override
  Widget build(BuildContext context) {
    final height = usage == null
        ? 2.0
        : usage!.totalTokens == 0 || max == 0
        ? 4.0
        : math.max(6.0, 68 * usage!.totalTokens / max);
    final label = usage == null
        ? '${date.month}月${date.day}日，无 Provider usage'
        : '${date.month}月${date.day}日，输入 ${_format(usage!.inputTokens)}，输出 ${_format(usage!.outputTokens)}';
    return Semantics(
      key: ValueKey('usage-day-${_dateKey(date)}'),
      label: label,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: FractionallySizedBox(
          widthFactor: 0.62,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: usage == null
                  ? context.cardStrokeColor.withValues(alpha: 0.55)
                  : context.accentColor.withValues(alpha: 0.30),
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
          ),
        ),
      ),
    );
  }
}

class _UsagePicker extends StatelessWidget {
  const _UsagePicker({required this.value, required this.onChanged});
  final _UsageView value;
  final ValueChanged<_UsageView> onChanged;
  @override
  Widget build(BuildContext context) => Container(
    height: 36,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: context.fieldColor,
      borderRadius: BorderRadius.circular(AppRadius.sm),
    ),
    child: Row(
      children: [
        _item(context, _UsageView.daily, '当天'),
        _item(context, _UsageView.monthly, '本月'),
        _item(context, _UsageView.all, '全部'),
      ],
    ),
  );
  Widget _item(BuildContext context, _UsageView item, String label) {
    final active = value == item;
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        child: InkWell(
          key: ValueKey('usage-view-${item.name}'),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          onTap: () => onChanged(item),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? context.cardColor : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.xs),
              boxShadow: active ? [context.cardShadow] : null,
            ),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: active ? context.textColor : context.subTextColor,
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryValues extends StatelessWidget {
  const _SummaryValues({super.key, required this.input, required this.output})
    : empty = null;
  factory _SummaryValues.fromDays({
    Key? key,
    required Iterable<HistoryTokenUsageDay> days,
    required String empty,
  }) {
    final list = days.toList();
    return _SummaryValues._(
      key: key,
      input: list.fold(0, (sum, d) => sum + d.inputTokens),
      output: list.fold(0, (sum, d) => sum + d.outputTokens),
      empty: list.isEmpty ? empty : null,
    );
  }
  const _SummaryValues._({
    super.key,
    required this.input,
    required this.output,
    required this.empty,
  });
  final int input;
  final int output;
  final String? empty;
  @override
  Widget build(BuildContext context) => empty != null
      ? _SummaryEmpty(empty!)
      : Row(
          children: [
            Expanded(child: _ValueTile('输入 tokens', input)),
            const SizedBox(width: 10),
            Expanded(child: _ValueTile('输出 tokens', output)),
          ],
        );
}

class _ValueTile extends StatelessWidget {
  const _ValueTile(this.label, this.value);
  final String label;
  final int value;
  @override
  Widget build(BuildContext context) => Container(
    height: 72,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: context.layerColor,
      borderRadius: BorderRadius.circular(AppRadius.sm),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: context.subTextColor,
            fontSize: 10,
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            _format(value),
            maxLines: 1,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: context.textColor,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

class _SummaryEmpty extends StatelessWidget {
  const _SummaryEmpty(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Container(
    height: 72,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: context.layerColor,
      borderRadius: BorderRadius.circular(AppRadius.sm),
    ),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: context.subTextColor),
    ),
  );
}

class _SummaryLoading extends StatelessWidget {
  const _SummaryLoading();
  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 72,
    child: Center(child: CircularProgressIndicator()),
  );
}

class _SummaryError extends StatelessWidget {
  const _SummaryError(this.error, this.retry);
  final Object? error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 72,
    child: _LoadError(error: error, retry: retry, compact: true),
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({
    required this.error,
    required this.retry,
    this.compact = false,
  });
  final Object? error;
  final VoidCallback retry;
  final bool compact;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _errorMessage(error),
          maxLines: compact ? 2 : 3,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: context.subTextColor),
        ),
        SizedBox(height: compact ? 2 : 8),
        TextButton(onPressed: retry, child: const Text('重试')),
      ],
    ),
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.error, required this.retry});
  final Object? error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          _errorMessage(error),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: context.subTextColor),
        ),
      ),
      TextButton(onPressed: retry, child: const Text('重试')),
    ],
  );
}

class _OfflineLabel extends StatelessWidget {
  const _OfflineLabel({this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) => Text(
    '离线缓存',
    style: Theme.of(context).textTheme.labelSmall?.copyWith(
      color: context.subTextColor,
      fontSize: compact ? 9 : 10,
    ),
  );
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
DateTime _parseDate(String value) {
  final p = value.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

String _two(int value) => value.toString().padLeft(2, '0');
String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';
DateTime _utcBoundary(DateTime date, int offset) => DateTime.utc(
  date.year,
  date.month,
  date.day,
).subtract(Duration(minutes: offset));
String _format(int value) {
  final s = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

String _errorMessage(Object? error) {
  final detail = error?.toString().trim() ?? '';
  return detail.isEmpty ? '历史加载失败' : '历史加载失败：$detail';
}
