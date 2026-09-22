import '../models/reading_book.dart';
import 'reading_api.dart';

/// 解析 8070 read_data.json 原始返回：过滤红线（BLOCKED）+ 按 updated 倒序。
List<ReadingBook>? parseReadingBooks(Object? raw) {
  if (raw is! Map) return null;
  final books = <ReadingBook>[];
  raw.forEach((k, v) {
    if (v is! Map<String, dynamic>) return;
    final book = ReadingBook.fromJson(v);
    if (ReadingApi.isBlocked(book.title)) return;
    if (ReadingApi.isBlocked(book.author)) return;
    books.add(book);
  });
  books.sort((a, b) => b.updated.compareTo(a.updated));
  return books;
}
