import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/gallery.dart';
import '../data/group_match.dart';
import '../scan/scan_controller.dart';
import '../share/group.dart';
import '../share/send_center.dart';
import 'aurora.dart';
import 'devices.dart' show deviceColor;
import 'gallery_view.dart';
import 'glass.dart';
import 'motion.dart';
import 'profile_screen.dart';
import 'sections.dart';
import 'widgets.dart';

/// Trip groups: everyone's phone in one group, so each photo goes only to
/// the people in it. Start one (others join with a 4-digit code) or join one
/// nearby; then pick the photos you're happy to share.
class TripGroupScreen extends StatefulWidget {
  const TripGroupScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<TripGroupScreen> createState() => _TripGroupScreenState();
}

class _TripGroupScreenState extends State<TripGroupScreen> {
  ScanController get c => widget.controller;
  GroupHub get hub => c.sharing.groups;
  final _name = TextEditingController();
  String? _shownEnded;

  @override
  void initState() {
    super.initState();
    hub.addListener(_onHub);
    if (hub.group == null) hub.search();
  }

  @override
  void dispose() {
    hub.removeListener(_onHub);
    _name.dispose();
    super.dispose();
  }

  void _onHub() {
    final ended = hub.ended;
    if (ended != null && ended != _shownEnded && mounted) {
      _shownEnded = ended;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ended)));
    }
  }

  /// Groups need your face; offers to set it up first.
  Future<bool> _needFace() async {
    if (c.profile.isSet) return true;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.face_retouching_natural_rounded),
        title: const Text('Set up your face first'),
        content: const Text('Friends\' phones use it to send you the photos you\'re in. You only do this once.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Set up')),
        ],
      ),
    );
    if (go == true && mounted) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileScreen(controller: c)));
    }
    return c.profile.isSet;
  }

  Future<void> _start() async {
    if (!await _needFace()) return;
    await hub.create(_name.text);
    Haptics.success();
  }

  Future<void> _join(NearbyGroup g) async {
    if (!await _needFace() || !mounted) return;
    final code = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Join ${g.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Type the code shown on ${g.hostAlias}.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          TextField(
            controller: code,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 4,
            textAlign: TextAlign.center,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 28, letterSpacing: 12, fontWeight: FontWeight.w700),
            decoration: const InputDecoration(counterText: '', hintText: '••••'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, code.text), child: const Text('Join')),
        ],
      ),
    );
    if (entered == null || entered.trim().isEmpty) return;
    final error = await hub.join(g, entered);
    if (!mounted) return;
    if (error != null) {
      Haptics.warn();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    } else {
      Haptics.success();
    }
  }

  Future<void> _leave(TripGroup g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(g.hosting ? 'End ${g.name}?' : 'Leave ${g.name}?'),
        content: Text(g.hosting
            ? 'Everyone leaves the group. Photos already sent stay on their phones.'
            : 'You won\'t get more photos from this group. Photos already sent stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(g.hosting ? 'End' : 'Leave')),
        ],
      ),
    );
    if (ok == true) {
      await hub.leave();
      unawaited(hub.search());
    }
  }

  Future<void> _share(TripGroup g) async {
    if (!await Gallery.requestAccess() || !mounted) return;
    final ids = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Pick photos to share')),
          body: GalleryView(
            controller: c,
            source: GallerySource.album(Gallery.allPhotos),
            onPicked: (ids) => Navigator.pop(context, ids),
          ),
        ),
      ),
    );
    if (ids == null || ids.isEmpty || !mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => GroupShareScreen(controller: c, assetIds: ids)));
  }

  @override
  Widget build(BuildContext context) {
    return Aurora(
      intensity: 0.7,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: ListenableBuilder(
          listenable: Listenable.merge([hub, c.sharing, c]),
          builder: (context, _) {
            final g = hub.group;
            return g == null ? _lobby(context) : _inGroup(context, g);
          },
        ),
      ),
    );
  }

  Widget _lobby(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassScrollView(
      title: 'Trip group',
      subtitle: 'Each photo goes only to the people in it',
      actions: [
        ToolbarCapsule(children: [
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.account_circle_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileScreen(controller: c))),
          ),
        ]),
      ],
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 32),
          sliver: SliverList.list(children: [
            if (!c.profile.isSet) ...[
              SectionCard(
                child: SectionRow(
                  leading: const IconTile(icon: Icons.face_retouching_natural_rounded, color: Color(0xFFFF9F0A)),
                  title: 'Set up your face',
                  subtitle: 'Once, in Profile. Groups need it to find your photos',
                  chevron: true,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileScreen(controller: c))),
                ),
              ).animate().fadeIn().moveY(begin: -6),
              const SizedBox(height: 12),
            ],
            SectionCard(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Row(children: [
                  IconTile(icon: Icons.diversity_3_rounded, color: Color(0xFF30D158)),
                  SizedBox(width: 14),
                  Text('Start a group', style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 14),
                Container(
                  decoration: BoxDecoration(color: capsuleFill(context), borderRadius: BorderRadius.circular(14)),
                  child: TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Trip name, e.g. Goa trip',
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: _start,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Start'),
                ),
              ]),
            ),
            SectionHeader(
              title: 'Nearby groups',
              trailing: hub.searching
                  ? const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.4)),
                    )
                  : IconButton(tooltip: 'Look again', onPressed: hub.search, icon: const Icon(Icons.refresh_rounded)),
            ),
            if (hub.nearby.isEmpty)
              SectionCard(
                padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
                child: Column(children: [
                  Icon(Icons.wifi_find_rounded, size: 40, color: scheme.onSurfaceVariant)
                      .animate(onPlay: (a) => a.repeat(reverse: true))
                      .scaleXY(end: 1.12, duration: 900.ms, curve: Curves.easeInOut),
                  const SizedBox(height: 10),
                  Text(hub.searching ? 'Looking for groups…' : 'No groups nearby yet',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('Be on the same Wi‑Fi or hotspot as the phone that started it.',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                ]),
              )
            else
              SectionCard.rows(rows: [
                for (final g in hub.nearby)
                  SectionRow(
                    leading: const IconTile(icon: Icons.luggage_rounded, color: Color(0xFF5E9BFF)),
                    title: g.name,
                    subtitle: 'Started by ${g.hostAlias} · ${g.count} ${g.count == 1 ? 'phone' : 'phones'}',
                    trailing: FilledButton.tonal(onPressed: () => _join(g), child: const Text('Join')),
                    onTap: () => _join(g),
                  ),
              ]).animate().fadeIn(),
            const SectionFooter(
              'Everyone needs ShareBro and their face set up in Profile. Phones talk over the same Wi‑Fi or a '
              'hotspot. Only the photos each person picks are shared, and only with the people in them.',
            ),
          ]),
        ),
      ],
    );
  }

  Widget _inGroup(BuildContext context, TripGroup g) {
    final scheme = Theme.of(context).colorScheme;
    final members = g.members.values.toList();
    final me = c.sharing.identity.fingerprint;
    final jobs = [for (final j in c.sharing.jobs) if (j.groupId == g.id) j];
    return GlassScrollView(
      title: g.name,
      subtitle: g.hosting ? 'Trip group · you started it' : 'Trip group · started by ${g.host?.alias ?? 'a friend'}',
      actions: [
        ToolbarCapsule(children: [
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.account_circle_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileScreen(controller: c))),
          ),
        ]),
      ],
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 32),
          sliver: SliverList.list(children: [
            if (g.hosting)
              SectionCard(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
                child: Column(children: [
                  Text('Join code', style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    for (final (i, d) in g.code.split('').indexed)
                      Container(
                        width: 58,
                        height: 70,
                        margin: const EdgeInsets.symmetric(horizontal: 5),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: capsuleFill(context), borderRadius: BorderRadius.circular(16)),
                        child: Text(d, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
                      ).animate().fadeIn(delay: (80 * i).ms).moveY(begin: 10, curve: Curves.easeOutBack),
                  ]),
                  const SizedBox(height: 12),
                  Text('Friends open ShareBro › Share › Trip group, pick "${g.name}" and type this code.',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant)),
                ]),
              ),
            SectionHeader(
              title: 'Members',
              top: g.hosting ? 26 : 8,
              badge: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(color: capsuleFill(context), borderRadius: BorderRadius.circular(99)),
                child: Text('${members.length}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
              ),
            ),
            SectionCard(
              padding: const EdgeInsets.fromLTRB(8, 18, 8, 14),
              child: Wrap(
                alignment: WrapAlignment.start,
                runSpacing: 14,
                children: [
                  for (final m in members)
                    SizedBox(
                      width: 72,
                      child: Column(children: [
                        Stack(clipBehavior: Clip.none, children: [
                          MemberAvatar(member: m, size: 54),
                          if (m.faces.isNotEmpty)
                            Positioned(
                              right: -3,
                              bottom: -3,
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: scheme.primary,
                                  border: Border.all(color: scheme.surfaceContainer, width: 2.5),
                                ),
                                child: Icon(Icons.check_rounded, size: 12, color: scheme.onPrimary),
                              ),
                            ),
                        ]),
                        const SizedBox(height: 6),
                        Text(m.fingerprint == me ? 'You' : _short(m.alias),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                        Text(m.faces.isEmpty ? 'No face yet' : 'Ready',
                            style: TextStyle(fontSize: 11, color: m.faces.isEmpty ? scheme.onSurfaceVariant : scheme.primary)),
                      ]),
                    ).animate(key: ValueKey(m.fingerprint)).scale(curve: Curves.easeOutBack, duration: 420.ms),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: members.length < 2 ? null : () => _share(g),
              icon: const Icon(Icons.photo_library_rounded),
              label: Text(members.length < 2 ? 'Waiting for friends to join' : 'Pick photos to share'),
            ),
            if (jobs.isNotEmpty) ...[
              const SectionHeader(title: 'Sending'),
              SectionCard.rows(rows: [for (final j in jobs) _jobRow(context, g, j)]),
            ],
            const SizedBox(height: 12),
            SectionCard(
              child: SectionRow(
                leading: const IconTile(icon: Icons.logout_rounded, color: Color(0xFFFF453A)),
                title: g.hosting ? 'End the group' : 'Leave the group',
                destructive: true,
                onTap: () => _leave(g),
              ),
            ),
            const SectionFooter(
              'Members\' phones accept photos from each other without asking while the group is open. '
              'The group lasts until it\'s ended or ShareBro is closed on the phone that started it.',
            ),
          ]),
        ),
      ],
    );
  }

  Widget _jobRow(BuildContext context, TripGroup g, SendJob j) {
    final scheme = Theme.of(context).colorScheme;
    final m = g.members[j.fingerprint];
    final status = switch (j.status) {
      JobStatus.done => 'Done · ${j.count} photos',
      JobStatus.sending => 'Sending ${math.min(j.filesDone + 1, j.count)} of ${j.count}',
      JobStatus.preparing => 'Getting ${j.count} photos ready',
      JobStatus.asking => 'Connecting…',
      JobStatus.waiting => j.message ?? 'Waiting · not nearby',
      JobStatus.cancelled => 'Cancelled',
      _ => j.message ?? 'Didn\'t go through',
    };
    return SectionRow(
      leading: m == null ? const Icon(Icons.smartphone_rounded) : MemberAvatar(member: m, size: 36),
      title: j.personName,
      subtitle: status,
      trailing: j.status == JobStatus.done
          ? Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primary),
              child: Icon(Icons.check_rounded, size: 18, color: scheme.onPrimary),
            ).animate().scale(curve: Curves.easeOutBack)
          : j.canRetry
              ? IconButton(tooltip: 'Try again', onPressed: () => c.sharing.retry(j), icon: const Icon(Icons.refresh_rounded))
              : SizedBox.square(
                  dimension: 30,
                  child: CircularProgressIndicator(
                    value: j.status == JobStatus.waiting ? 0 : j.progress,
                    strokeWidth: 3.5,
                    strokeCap: StrokeCap.round,
                    backgroundColor: capsuleFill(context),
                  ),
                ),
    );
  }

  static String _short(String alias) => alias.endsWith("'s Pixel") || alias.contains("'s ") ? alias.split("'s ").first : alias;
}

/// A member's face crop, or their initial on a flat colour.
class MemberAvatar extends StatelessWidget {
  const MemberAvatar({super.key, required this.member, required this.size});

  final GroupMember member;
  final double size;

  @override
  Widget build(BuildContext context) {
    final thumb = member.thumb;
    final color = deviceColor(member.fingerprint);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      child: thumb == null
          ? Text(member.alias.isEmpty ? '?' : member.alias[0].toUpperCase(),
              style: TextStyle(fontSize: size * 0.4, fontWeight: FontWeight.w700, color: Colors.white))
          : Image.memory(thumb, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }
}

enum _Phase { looking, matching, review, ready }

/// After picking photos: works out who's in each one, shows copies flying
/// to the people in them, asks about faces it isn't sure of, then sends.
class GroupShareScreen extends StatefulWidget {
  const GroupShareScreen({super.key, required this.controller, required this.assetIds});

  final ScanController controller;
  final List<String> assetIds;

  @override
  State<GroupShareScreen> createState() => _GroupShareScreenState();
}

class _GroupShareScreenState extends State<GroupShareScreen> {
  ScanController get c => widget.controller;
  _Phase _phase = _Phase.looking;
  GroupPlan? _plan;
  int _looked = 0, _toLook = 0;

  /// Animation state: the photo in the middle, copies landed per member.
  String? _center;
  final Map<String, int> _landed = {};
  final List<_Flight> _flights = [];
  int _checked = 0, _out = 0, _stay = 0, _review = 0;
  bool _skip = false;
  late final TripGroup? _group = c.sharing.groups.group;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _skip = true;
    super.dispose();
  }

  List<GroupMember> get _others =>
      [for (final m in _group?.members.values ?? const <GroupMember>[]) if (m.fingerprint != c.sharing.identity.fingerprint) m];

  Future<void> _run() async {
    final g = _group;
    if (g == null) return;
    final me = c.sharing.identity.fingerprint;
    final plan = await c.planGroupSend(
      {
        for (final m in g.members.values) m.fingerprint: m.fingerprint == me ? c.profile.faces : m.faces,
      },
      me,
      widget.assetIds,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _looked = done;
          _toLook = total;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _phase = _Phase.matching;
    });
    await _animate(plan);
    if (!mounted) return;
    setState(() => _phase = plan.unsure.isEmpty ? _Phase.ready : _Phase.review);
  }

  /// One photo at a time into the middle, then a copy to each person in
  /// it. Long picks speed up; Skip jumps to the end.
  Future<void> _animate(GroupPlan plan) async {
    final reduce = MediaQuery.disableAnimationsOf(context);
    for (final (i, id) in plan.order.indexed) {
      if (!mounted) return;
      final to = plan.faces[id] ?? const <String>{};
      final unsure = plan.unsure.where((u) => u.assetId == id).length;
      if (_skip || reduce || i >= 40) {
        _checked++;
        _review += unsure;
        if (to.isEmpty && unsure == 0) _stay++;
        _out += to.length;
        for (final k in to) {
          _landed[k] = (_landed[k] ?? 0) + 1;
        }
        continue;
      }
      final beat = i < 3 ? 900 : i < 10 ? 520 : 300;
      setState(() => _center = id);
      await Future<void>.delayed(Duration(milliseconds: beat ~/ 2));
      if (!mounted) return;
      setState(() {
        _checked++;
        _review += unsure;
        if (to.isEmpty && unsure == 0) _stay++;
        for (final k in to) {
          _flights.add(_Flight(id, k, UniqueKey()));
        }
      });
      await Future<void>.delayed(Duration(milliseconds: beat ~/ 2));
    }
    if (!mounted) return;
    // Let the last copies land.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) setState(() => _center = null);
  }

  void _landedAt(_Flight f) {
    if (!mounted) return;
    setState(() {
      _flights.remove(f);
      _landed[f.member] = (_landed[f.member] ?? 0) + 1;
      _out++;
    });
  }

  void _answer(UnsureFace u, bool yes) {
    Haptics.tick();
    final plan = _plan!;
    setState(() {
      if (yes) plan.accept(u);
      plan.unsure.remove(u);
      if (plan.unsure.isEmpty) _phase = _Phase.ready;
    });
  }

  Future<void> _send() async {
    final plan = _plan!, g = _group;
    if (g == null || c.sharing.groups.group?.id != g.id) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The group has ended.')));
      return;
    }
    for (final e in plan.send.entries) {
      final m = g.members[e.key];
      if (m == null || e.value.isEmpty) continue;
      await c.sharing.enqueue(personName: m.alias, assetIds: e.value, device: m.device, groupId: g.id);
    }
    Haptics.success();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = _plan;
    final friends = plan == null ? 0 : plan.send.values.where((l) => l.isNotEmpty).length;
    return Aurora(
      intensity: 0.7,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: GlassScrollView(
          title: switch (_phase) {
            _Phase.looking || _Phase.matching => 'Who\'s in each photo',
            _Phase.review => 'Quick check',
            _Phase.ready => 'Ready to send',
          },
          subtitle: switch (_phase) {
            _Phase.looking => _toLook == 0 ? 'Looking at faces…' : 'Looking at new photos · $_looked of $_toLook',
            _Phase.matching => 'Checked on this phone, nothing sent yet',
            _Phase.review => 'So nothing goes to the wrong person',
            _Phase.ready => '${widget.assetIds.length} photos · $friends ${friends == 1 ? 'friend' : 'friends'} in them',
          },
          actions: [
            if (_phase == _Phase.matching)
              ToolbarCapsule(children: [
                TextButton(onPressed: () => setState(() => _skip = true), child: const Text('Skip')),
              ]),
          ],
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 32),
              sliver: SliverList.list(children: [
                if (_phase == _Phase.review)
                  _ReviewCard(
                    key: ValueKey(plan!.unsure.first),
                    face: plan.unsure.first,
                    member: _group!.members[plan.unsure.first.member]!,
                    left: plan.unsure.length,
                    onAnswer: (yes) => _answer(plan.unsure.first, yes),
                  )
                else
                  SectionCard(
                    child: SizedBox(
                      height: 380,
                      child: _Orbit(
                        members: _others,
                        center: _center,
                        landed: _landed,
                        flights: _flights,
                        onLanded: _landedAt,
                        done: _phase == _Phase.ready,
                        working: _phase == _Phase.looking,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                SectionCard(
                  child: Row(children: [
                    _Stat(value: _checked, label: 'Checked'),
                    _Stat(value: _out, label: 'Copies to send'),
                    _Stat(value: _stay, label: 'Stay with you'),
                  ]),
                ),
                const SizedBox(height: 18),
                if (_phase == _Phase.ready)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    onPressed: friends == 0 ? null : _send,
                    icon: const Icon(Icons.send_rounded),
                    label: Text(friends == 0
                        ? 'Nobody from the group is in these'
                        : 'Send to $friends ${friends == 1 ? 'friend' : 'friends'}'),
                  ).animate().fadeIn().moveY(begin: 10)
                else if (_phase == _Phase.matching && _review > 0)
                  Text('$_review ${_review == 1 ? 'face' : 'faces'} to check after this',
                      textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                SectionFooter(
                  _phase == _Phase.ready && plan != null
                      ? 'Each friend gets only the photos they\'re in. ${plan.stay} '
                          '${plan.stay == 1 ? 'photo has' : 'photos have'} nobody else from the group and stay on this phone.'
                      : 'Faces are compared on this phone with the group\'s face fingerprints.',
                  align: TextAlign.center,
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _Flight {
  _Flight(this.assetId, this.member, this.key);

  final String assetId, member;
  final Key key;
}

/// Friends in a ring, the photo being checked in the middle, and copies
/// flying out to the people in it.
class _Orbit extends StatelessWidget {
  const _Orbit({
    required this.members,
    required this.center,
    required this.landed,
    required this.flights,
    required this.onLanded,
    required this.done,
    required this.working,
  });

  final List<GroupMember> members;
  final String? center;
  final Map<String, int> landed;
  final List<_Flight> flights;
  final ValueChanged<_Flight> onLanded;
  final bool done, working;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final mid = Offset(box.maxWidth / 2, box.maxHeight / 2);
      final r = math.min(box.maxWidth, box.maxHeight) / 2 - 44;
      Offset at(int i) {
        final a = -math.pi / 2 + i / math.max(1, members.length) * math.pi * 2;
        return mid + Offset(math.cos(a), math.sin(a)) * r;
      }

      final where = {for (final (i, m) in members.indexed) m.fingerprint: at(i)};
      return Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(child: CustomPaint(painter: _RingsPainter(r, scheme.onSurface.withValues(alpha: 0.08)))),
        for (final (i, m) in members.indexed)
          Positioned(
            left: at(i).dx - 34,
            top: at(i).dy - 28,
            width: 68,
            child: Column(children: [
              Stack(clipBehavior: Clip.none, children: [
                MemberAvatar(member: m, size: 50)
                    .animate(key: ValueKey('${m.fingerprint}-${landed[m.fingerprint] ?? 0}'))
                    .scaleXY(begin: 1.18, end: 1, duration: 320.ms, curve: Curves.easeOut),
                if ((landed[m.fingerprint] ?? 0) > 0)
                  Positioned(
                    right: -6,
                    top: -4,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 22),
                      height: 22,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: scheme.surfaceContainer, width: 2),
                      ),
                      child: Text('${landed[m.fingerprint]}',
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: scheme.onPrimary)),
                    ).animate().scale(curve: Curves.easeOutBack),
                  ),
              ]),
              const SizedBox(height: 4),
              Text(m.alias.split("'s ").first,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
            ]),
          ),
        Positioned(
          left: mid.dx - 58,
          top: mid.dy - 58,
          width: 116,
          height: 116,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            transitionBuilder: (child, a) => ScaleTransition(scale: Tween(begin: 0.6, end: 1.0).animate(a), child: FadeTransition(opacity: a, child: child)),
            child: working
                ? const Center(key: ValueKey('working'), child: CircularProgressIndicator())
                : done || center == null
                    ? Container(
                        key: const ValueKey('done'),
                        margin: const EdgeInsets.all(10),
                        decoration: BoxDecoration(shape: BoxShape.circle, color: done ? scheme.primary : Colors.transparent),
                        child: done ? Icon(Icons.check_rounded, size: 52, color: scheme.onPrimary) : null,
                      )
                    : ClipRRect(
                        key: ValueKey(center),
                        borderRadius: BorderRadius.circular(18),
                        child: Stack(fit: StackFit.expand, children: [
                          AssetThumb(id: center!, size: 300),
                          Align(
                            alignment: Alignment.topCenter,
                            child: Container(height: 2.5, color: scheme.primary),
                          ).animate().moveY(begin: 0, end: 113, duration: 420.ms, curve: Curves.easeInOut).fadeOut(delay: 300.ms),
                        ]),
                      ),
          ),
        ),
        for (final f in flights)
          if (where[f.member] != null)
            TweenAnimationBuilder<double>(
              key: f.key,
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 560),
              curve: Curves.easeInOutCubic,
              onEnd: () => onLanded(f),
              child: ClipRRect(borderRadius: BorderRadius.circular(8), child: AssetThumb(id: f.assetId, size: 120)),
              builder: (context, t, child) {
                final to = where[f.member]!;
                final d = to - mid;
                // A gentle arc: out sideways, then into their avatar.
                final bend = Offset(-d.dy, d.dx) / math.max(1, d.distance) * 30;
                final p = mid + d * t + bend * (4 * t * (1 - t));
                final s = 44 * (1.2 - 0.75 * t);
                return Positioned(
                  left: p.dx - s / 2,
                  top: p.dy - s / 2,
                  width: s,
                  height: s,
                  child: Opacity(opacity: (1.4 - t).clamp(0.0, 1.0), child: child),
                );
              },
            ),
      ]);
    });
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.r, this.color);

  final double r;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    final c = size.center(Offset.zero);
    canvas.drawCircle(c, r, p);
    canvas.drawCircle(c, r * 0.6, p);
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.r != r || old.color != color;
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(children: [
          RollingCount(value: value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// "Is this Maya?": the face from the photo next to their profile picture.
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({super.key, required this.face, required this.member, required this.left, required this.onAnswer});

  final UnsureFace face;
  final GroupMember member;
  final int left;
  final ValueChanged<bool> onAnswer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = member.alias.split("'s ").first;
    final thumb = face.thumb;
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 20),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 112,
            height: 112,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surfaceContainerHighest),
            child: thumb == null ? const Icon(Icons.face_rounded, size: 56) : Image.memory(thumb, fit: BoxFit.cover),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: CircleAvatar(
              radius: 17,
              backgroundColor: capsuleFill(context),
              child: Text('?', style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurfaceVariant)),
            ),
          ),
          MemberAvatar(member: member, size: 112),
        ]),
        const SizedBox(height: 20),
        Text('Is this $name?', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        const SizedBox(height: 6),
        Text('The face is a little hard to tell. Say yes and $name gets this photo too.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.4, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(
            flex: 2,
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              onPressed: () => onAnswer(false),
              icon: const Icon(Icons.close_rounded),
              label: const Text('No'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              onPressed: () => onAnswer(true),
              icon: const Icon(Icons.check_rounded),
              label: Text('Yes, it\'s $name'),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Text(left == 1 ? 'Last one' : '$left left', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
      ]),
    ).animate().fadeIn(duration: 250.ms).slideX(begin: 0.15, curve: Curves.easeOutCubic);
  }
}
