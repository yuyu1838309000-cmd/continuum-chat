import 'package:flutter/material.dart';

/// 日记心情颜色：只认 mood_score（0-10），不再用 mood 文字/emoji 自动猜。
/// mood 字段继续存文字（难过/平静/开心）只做展示，不参与颜色计算。
/// mood_score 为空（NULL）时用默认中性色。
///
/// 颜色档位：0-4 冷/浅、5-6 中性、7-10 暖/深；同一档内数值越大颜色越靠近暖/深。

const Color _diaryDefaultColor = Color(0xFFE3D3B2);

Color diaryMoodColor(int? score) {
  if (score == null) return _diaryDefaultColor;
  final s = score < 0 ? 0 : (score > 10 ? 10 : score);
  if (s <= 4) {
    const cold = [
      Color(0xFF8FAFC4), // 0
      Color(0xFF9DBACB), // 1
      Color(0xFFA9C2D1), // 2
      Color(0xFFB5C9D6), // 3
      Color(0xFFC1D0DC), // 4
    ];
    return cold[s];
  }
  if (s <= 6) {
    return s == 5 ? const Color(0xFFE3D3B2) : const Color(0xFFEADBB8);
  }
  const warm = [
    Color(0xFFF2B878), // 7
    Color(0xFFED9B62), // 8
    Color(0xFFE5864F), // 9
    Color(0xFFE07A4F), // 10
  ];
  return warm[s - 7];
}

Color diaryMoodTextColor(int? score) {
  final s = score ?? 5;
  return s <= 4 ? const Color(0xFF3D5567) : const Color(0xFF4A3B2A);
}

/// 日期总览图例：冷/浅、中性、暖/深三档（图例颜色与格子颜色同一映射）。
const List<({String label, Color color})> diaryMoodLegend = [
  (label: '冷/浅 0-4', color: Color(0xFFA9C2D1)),
  (label: '中性 5-6', color: Color(0xFFE3D3B2)),
  (label: '暖/深 7-10', color: Color(0xFFED9B62)),
];
