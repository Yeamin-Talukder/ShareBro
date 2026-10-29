import 'db.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "12 Oct 2026"
String formatDay(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// "12 Oct – 18 Oct 2026", or a single day.
String formatSpan(DaySpan s) {
  final a = s.start, b = s.end;
  if (a.year == b.year && a.month == b.month && a.day == b.day) {
    return formatDay(a);
  }
  final left = a.year == b.year ? '${a.day} ${_months[a.month - 1]}' : formatDay(a);
  return '$left – ${formatDay(b)}';
}

/// Section header for the gallery: Today, Yesterday, or "Mon, 12 Oct 2026".
String formatSectionDay(DateTime d, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final day = DateTime(d.year, d.month, d.day);
  final diff = DateTime(today.year, today.month, today.day).difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return '${_weekdays[d.weekday - 1]}, ${formatDay(d)}';
}

/// "3:07 PM"
String formatTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
}

const _fullMonths = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "October 2026"
String formatMonth(DateTime d) => '${_fullMonths[d.month - 1]} ${d.year}';

/// "Oct 2026"
String formatShortMonth(DateTime d) => '${_months[d.month - 1]} ${d.year}';

/// "2.4 MB"
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
