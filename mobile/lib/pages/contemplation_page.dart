import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/contemplation_api.dart';
import '../utils/app_theme.dart';

typedef ContemplationPageLoader =
    Future<int?> Function({void Function(int count)? onCached});

/// 沉思室只展示房间与真实次数；不请求或展示任何沉思正文。
class ContemplationPage extends StatefulWidget {
  const ContemplationPage({
    super.key,
    this.countLoader = ContemplationApi.count,
  });

  final ContemplationPageLoader countLoader;

  @override
  State<ContemplationPage> createState() => _ContemplationPageState();
}

class _ContemplationPageState extends State<ContemplationPage> {
  int? _count;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final n = await widget.countLoader(onCached: _showCachedCount);
    if (!mounted) return;
    setState(() => _count = n);
  }

  void _showCachedCount(int count) {
    if (!mounted) return;
    setState(() => _count = count);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foregroundBase = context.isDark
        ? theme.colorScheme.onSurface
        : theme.colorScheme.surface;
    final quietText = foregroundBase.withValues(alpha: 0.56);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: context.scrimColor,
        body: SafeArea(
          child: Stack(
            children: [
              Align(
                alignment: const Alignment(0, -0.28),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '沉思室',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.w300,
                          letterSpacing: 4,
                          color: foregroundBase.withValues(alpha: 0.94),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Text(
                        '这里记录 AI 助手的独立思考。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: AppType.caption,
                          height: 1.6,
                          color: quietText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '返回',
                  icon: Icon(
                    Icons.chevron_left,
                    size: 28,
                    color: foregroundBase.withValues(alpha: 0.78),
                  ),
                ),
              ),
              if (_count case final count?)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                    child: Text(
                      '已独坐 $count 次',
                      key: const ValueKey('contemplation_count'),
                      style: TextStyle(
                        fontSize: AppType.timestamp,
                        color: foregroundBase.withValues(alpha: 0.46),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
