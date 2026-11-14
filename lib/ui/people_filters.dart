import 'package:flutter/material.dart';

import '../data/db.dart';
import 'motion.dart';
import 'people_space.dart';
import 'sections.dart';

/// The People page's filter bar keeps one button per question (which trip,
/// who, when, which view); these are the short lists those buttons open.

/// A round chip that is only an icon: the calendar and the view picker.
class IconChip extends StatelessWidget {
  const IconChip({super.key, required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Pressable(
          onTap: onTap,
          scale: 0.9,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: capsuleFill(context), shape: BoxShape.circle),
            child: Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}

/// A small square button inside a card ("Timeline", "Map").
class SquareButton extends StatelessWidget {
  const SquareButton({super.key, required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Pressable(
          onTap: onTap,
          scale: 0.9,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: capsuleFill(context), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 19, color: Theme.of(context).colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}

/// A titled sheet that is only as tall as what's in it.
Future<T?> _showPickSheet<T>(BuildContext context, String title, List<Widget> Function(BuildContext) rows) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.72),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 6),
              child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            ),
            ...rows(context),
          ]),
        ),
      ),
    ),
  );
}

Widget _pickRow(
  BuildContext context, {
  required IconData icon,
  required String title,
  String? subtitle,
  bool selected = false,
  VoidCallback? onTap,
  VoidCallback? onLongPress,
}) {
  final scheme = Theme.of(context).colorScheme;
  return ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 22),
    leading: Icon(icon, color: selected ? scheme.primary : scheme.onSurfaceVariant),
    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: subtitle == null ? null : Text(subtitle),
    trailing: selected ? Icon(Icons.check_rounded, color: scheme.primary) : null,
    onTap: onTap,
    onLongPress: onLongPress,
  );
}

Widget _sheetNote(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 4),
      child: Text(text, style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );

/// Which trip to show. [onPick] gets the trip's id, or null for all of
/// them; holding a trip calls [onEdit] (rename or remove).
Future<void> showTripSheet(
  BuildContext context, {
  required List<TripSummary> trips,
  required int? selected,
  required ValueChanged<int?> onPick,
  required ValueChanged<TripSummary> onEdit,
}) {
  void pick(BuildContext sheet, int? id) {
    Haptics.tick();
    Navigator.pop(sheet);
    onPick(id);
  }

  return _showPickSheet<void>(context, 'Trip', (sheet) => [
        _pickRow(
          sheet,
          icon: Icons.groups_rounded,
          title: 'All trips',
          subtitle: 'Everyone from every scan',
          selected: selected == null,
          onTap: () => pick(sheet, null),
        ),
        for (final t in trips)
          _pickRow(
            sheet,
            icon: Icons.luggage_rounded,
            title: t.name,
            subtitle: '${t.photoCount} photos',
            selected: selected == t.id,
            onTap: () => pick(sheet, t.id),
            onLongPress: () {
              Navigator.pop(sheet);
              onEdit(t);
            },
          ),
        _sheetNote(sheet, 'Hold a trip to rename or remove it.'),
      ]);
}

/// Who to show: everyone, only men or women, and one of the saved groups.
/// [genders] are the choices worth offering, each with how many people.
Future<void> showWhoSheet(
  BuildContext context, {
  required int everyone,
  required Map<Gender, int> genders,
  required Gender? gender,
  required List<PersonGroup> groups,
  required int? groupId,
  required ValueChanged<Gender?> onGender,
  required ValueChanged<int?> onGroup,
  required VoidCallback onNewGroup,
  required ValueChanged<PersonGroup> onEditGroup,
}) {
  return _showPickSheet<void>(context, 'Who', (sheet) => [
        if (genders.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
            child: CapsuleSwitch<Gender?>(
              value: gender,
              options: [
                (null, 'Everyone', everyone),
                for (final MapEntry(key: g, value: n) in genders.entries) (g, g == Gender.male ? 'Men' : 'Women', n),
              ],
              onChanged: (g) {
                Navigator.pop(sheet);
                onGender(g);
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
          child: Text('Groups',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: Theme.of(sheet).colorScheme.onSurfaceVariant)),
        ),
        for (final g in groups)
          _pickRow(
            sheet,
            icon: Icons.diversity_3_rounded,
            title: g.name,
            subtitle: '${g.members.length} ${g.members.length == 1 ? 'person' : 'people'}',
            selected: groupId == g.id,
            onTap: () {
              Haptics.tick();
              Navigator.pop(sheet);
              onGroup(groupId == g.id ? null : g.id);
            },
            onLongPress: () {
              Navigator.pop(sheet);
              onEditGroup(g);
            },
          ),
        _pickRow(
          sheet,
          icon: Icons.add_rounded,
          title: 'New group',
          onTap: () {
            Navigator.pop(sheet);
            onNewGroup();
          },
        ),
        if (groups.isNotEmpty) _sheetNote(sheet, 'Hold a group to change who is in it.'),
      ]);
}

/// How People is laid out: the grid, bubbles, or a spatial view.
Future<PeopleLayout?> showViewSheet(BuildContext context, PeopleLayout current) {
  return _showPickSheet<PeopleLayout>(context, 'View', (sheet) {
    final scheme = Theme.of(sheet).colorScheme;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 6),
        child: GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.08,
          children: [
            for (final l in PeopleLayout.values)
              Semantics(
                button: true,
                selected: l == current,
                child: Pressable(
                  onTap: () => Navigator.pop(sheet, l),
                  scale: 0.93,
                  child: Container(
                    decoration: BoxDecoration(
                      color: l == current ? scheme.primary : capsuleFill(sheet),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(l.icon, size: 24, color: l == current ? scheme.onPrimary : scheme.onSurface),
                      const SizedBox(height: 6),
                      Text(l.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: l == current ? scheme.onPrimary : scheme.onSurface,
                          )),
                    ]),
                  ),
                ),
              ),
          ],
        ),
      ),
    ];
  });
}
