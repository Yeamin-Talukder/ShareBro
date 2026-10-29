import 'package:flutter/material.dart';

import '../data/db.dart';
import '../scan/scan_controller.dart';

/// Create or edit a saved group of people ("Family", "Office friends").
/// Returns true if something was saved or deleted.
Future<bool> showGroupEditor(BuildContext context, ScanController controller,
    {PersonGroup? group}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _GroupEditor(controller: controller, group: group),
    ),
  );
  return result ?? false;
}

class _GroupEditor extends StatefulWidget {
  const _GroupEditor({required this.controller, this.group});

  final ScanController controller;
  final PersonGroup? group;

  @override
  State<_GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends State<_GroupEditor> {
  late final _name = TextEditingController(text: widget.group?.name ?? '');
  late final Set<int> _members = {...?widget.group?.members};
  List<PersonSummary> _people = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.db.people().then((p) {
      if (mounted) setState(() => _people = p);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _members.isEmpty) return;
    await widget.controller.db.saveGroup(widget.group?.id, _name.text, _members);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final named = [for (final p in _people) if (p.name != null) p];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: TextField(
            controller: _name,
            autofocus: widget.group == null,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: 'Group name', hintText: 'Family, Office friends…'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: named.isEmpty
              ? const Center(child: Text('Name some people first.'))
              : ListView(children: [
                  for (final p in named)
                    CheckboxListTile(
                      value: _members.contains(p.id),
                      onChanged: (v) =>
                          setState(() => v! ? _members.add(p.id) : _members.remove(p.id)),
                      secondary: CircleAvatar(
                        backgroundImage:
                            p.coverThumb == null ? null : MemoryImage(p.coverThumb!),
                      ),
                      title: Text(p.displayName),
                      subtitle: p.nickname == null ? null : Text(p.nickname!),
                    ),
                ]),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              if (widget.group != null)
                TextButton(
                  onPressed: () async {
                    await widget.controller.db.deleteGroup(widget.group!.id);
                    if (context.mounted) Navigator.pop(context, true);
                  },
                  child: const Text('Delete group'),
                ),
              const Spacer(),
              FilledButton(
                onPressed:
                    _name.text.trim().isEmpty || _members.isEmpty ? null : _save,
                child: Text('Save · ${_members.length}'),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
