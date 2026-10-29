import 'package:flutter/material.dart';

/// An icon and colour for a file, from its MIME type or name.
({IconData icon, Color color}) fileLook(String? mime, [String? name]) {
  final m = mime ?? '';
  final ext = (name ?? '').contains('.') ? name!.split('.').last.toLowerCase() : '';
  if (m.startsWith('image/')) return (icon: Icons.image_rounded, color: const Color(0xFFE8457A));
  if (m.startsWith('video/')) return (icon: Icons.movie_rounded, color: const Color(0xFF6E5BFF));
  if (m.startsWith('audio/')) return (icon: Icons.music_note_rounded, color: const Color(0xFFFF8A5C));
  if (m.startsWith('text/')) return (icon: Icons.notes_rounded, color: const Color(0xFF2BB5A6));
  if (m == 'application/pdf') return (icon: Icons.picture_as_pdf_rounded, color: const Color(0xFFD9432B));
  if (m.contains('zip') || m.contains('rar') || m.contains('7z')) {
    return (icon: Icons.folder_zip_rounded, color: const Color(0xFFB8860B));
  }
  if (m.contains('android.package') || ext == 'apk') return (icon: Icons.android_rounded, color: const Color(0xFF3DDC84));
  if (m.contains('word') || ext == 'doc' || ext == 'docx') {
    return (icon: Icons.description_rounded, color: const Color(0xFF2B6CD9));
  }
  if (m.contains('sheet') || m.contains('excel') || ext == 'csv') {
    return (icon: Icons.table_chart_rounded, color: const Color(0xFF1E8E4E));
  }
  if (m.contains('presentation') || m.contains('powerpoint')) {
    return (icon: Icons.slideshow_rounded, color: const Color(0xFFD9632B));
  }
  return (icon: Icons.insert_drive_file_rounded, color: const Color(0xFF7A869A));
}

/// A rounded, tinted file-type badge.
class FileBadge extends StatelessWidget {
  const FileBadge({super.key, this.mime, this.name, this.size = 44});

  final String? mime;
  final String? name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final look = fileLook(mime, name);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: look.color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(look.icon, color: look.color, size: size * 0.55),
    );
  }
}
