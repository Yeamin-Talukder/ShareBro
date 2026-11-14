/// What GitHub says about a ShareBro release, and the small pure helpers
/// the updater needs: comparing versions, picking the right APK for this
/// phone, reading SHA256SUMS.txt and turning release notes into a list.
library;

/// "1.4.0", "v1.5.0", "1.5.0+8" or "1.5.0-beta.1" as numbers to compare.
class Version implements Comparable<Version> {
  Version(this.parts);

  /// Null when [s] has no version number in it.
  static Version? tryParse(String s) {
    final m = RegExp(r'(\d+(?:\.\d+)*)').firstMatch(s.trim());
    if (m == null) return null;
    return Version(m.group(1)!.split('.').map(int.parse).toList());
  }

  final List<int> parts;

  @override
  int compareTo(Version other) {
    final n = parts.length > other.parts.length ? parts.length : other.parts.length;
    for (var i = 0; i < n; i++) {
      final a = i < parts.length ? parts[i] : 0;
      final b = i < other.parts.length ? other.parts[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  bool operator >(Version other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll(parts.reversed.skipWhile((p) => p == 0));

  @override
  String toString() => parts.join('.');
}

/// One file attached to a release.
class ReleaseAsset {
  const ReleaseAsset(this.name, this.url, this.size);

  final String name;
  final String url;
  final int size;
}

/// The latest release on GitHub.
class Release {
  const Release({
    required this.version,
    required this.tag,
    required this.notes,
    required this.assets,
    this.summary = '',
    this.published,
    this.page,
  });

  /// From the GitHub REST API's release object.
  factory Release.fromGitHub(Map<String, Object?> json) {
    final tag = (json['tag_name'] as String?) ?? '';
    return Release(
      version: Version.tryParse(tag) ?? Version([0]),
      tag: tag,
      notes: parseNotes((json['body'] as String?) ?? ''),
      summary: parseSummary((json['body'] as String?) ?? ''),
      published: DateTime.tryParse((json['published_at'] as String?) ?? ''),
      page: json['html_url'] as String?,
      assets: [
        for (final a in (json['assets'] as List? ?? const []).cast<Map>())
          ReleaseAsset(
            a['name'] as String? ?? '',
            a['browser_download_url'] as String? ?? '',
            (a['size'] as num?)?.toInt() ?? 0,
          ),
      ],
    );
  }

  final Version version;
  final String tag;
  final List<ReleaseNote> notes;

  /// The release's opening paragraph.
  final String summary;
  final List<ReleaseAsset> assets;
  final DateTime? published;
  final String? page;

  /// The APK built for one of [abis] (best first, as Android lists them),
  /// else a universal APK; null if the release has none.
  ReleaseAsset? apkFor(List<String> abis) {
    final apks = assets.where((a) => a.name.toLowerCase().endsWith('.apk')).toList();
    for (final abi in abis) {
      for (final a in apks) {
        if (a.name.toLowerCase().contains(abi.toLowerCase())) return a;
      }
    }
    const known = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];
    for (final a in apks) {
      if (!known.any((k) => a.name.toLowerCase().contains(k))) return a;
    }
    return null;
  }

  ReleaseAsset? get checksums {
    for (final a in assets) {
      if (a.name.toLowerCase().startsWith('sha256sums')) return a;
    }
    return null;
  }
}

/// "abc123…  ShareBro-v1.5.0-arm64-v8a.apk" lines as file name → hash.
Map<String, String> parseSums(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$').firstMatch(line.trim());
    if (m != null) out[m.group(2)!.split('/').last] = m.group(1)!.toLowerCase();
  }
  return out;
}

/// One point in "What's new": the bold lead ("Search by place") and the
/// rest of the sentence.
class ReleaseNote {
  const ReleaseNote(this.title, this.text);

  final String title;
  final String text;

  @override
  String toString() => title.isEmpty ? text : '$title: $text';
}

/// The bullet points under "What's new" in a release description (or every
/// bullet when there's no such heading), without Markdown.
List<ReleaseNote> parseNotes(String body, {int max = 10}) {
  final lines = body.replaceAll('\r', '').split('\n');
  final heading = RegExp(r'^\s*#{1,6}\s*(.+?)\s*$');
  final news = lines.indexWhere((l) => heading.firstMatch(l)?.group(1)?.toLowerCase().startsWith("what") ?? false);
  final out = <ReleaseNote>[];
  for (final raw in news < 0 ? lines : lines.skip(news + 1)) {
    if (news >= 0 && heading.hasMatch(raw)) break;
    final m = RegExp(r'^\s*[-*•]\s+(.+)$').firstMatch(raw);
    if (m == null) continue;
    var s = m.group(1)!.trim();
    var title = '';
    final lead = RegExp(r'^\*\*(.+?)\*\*\s*').firstMatch(s);
    if (lead != null) {
      title = _plain(lead.group(1)!).replaceAll(RegExp(r'[.:]$'), '');
      s = s.substring(lead.end);
    }
    final text = _plain(s);
    if (title.isEmpty && text.isEmpty) continue;
    if (text.toLowerCase().contains('full changelog')) continue;
    out.add(ReleaseNote(title, text));
    if (out.length == max) break;
  }
  return out;
}

/// The first paragraph of a release description, without Markdown.
String parseSummary(String body) {
  for (final para in body.replaceAll('\r', '').split(RegExp(r'\n\s*\n'))) {
    final t = para.trim();
    if (t.isEmpty || t.startsWith('#') || t.startsWith('|') || t.startsWith('-')) continue;
    return _plain(t.replaceAll('\n', ' '));
  }
  return '';
}

String _plain(String s) => s
    .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
    .replaceAll(RegExp(r'\*\*|__|`'), '')
    .replaceAllMapped(RegExp(r'(^|[\s(])\*([^*\s][^*]*?)\*(?=$|[\s.,;:!?)])'), (m) => '${m.group(1)}${m.group(2)}')
    .trim();

/// The architecture as people know it: "arm64" for arm64-v8a.
String shortAbi(String assetName) {
  final n = assetName.toLowerCase();
  if (n.contains('arm64')) return 'arm64';
  if (n.contains('armeabi')) return '32-bit ARM';
  if (n.contains('x86_64')) return 'x86_64';
  return 'universal';
}

/// "today", "yesterday", "3 days ago", "2 weeks ago", "Mar 2026".
String releasedAgo(DateTime when, DateTime now) {
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(when.year, when.month, when.day)).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 14) return '$days days ago';
  if (days < 60) return '${days ~/ 7} weeks ago';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[when.month - 1]} ${when.year}';
}
