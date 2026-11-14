import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/db.dart';
import 'package:photo_organizer/ui/people_filters.dart';
import 'package:photo_organizer/ui/people_space.dart';
import 'package:photo_organizer/ui/sections.dart';

/// A phone-sized page with one button that runs [open].
Future<void> _page(WidgetTester tester, void Function(BuildContext) open) async {
  tester.view.physicalSize = const Size(412, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(onPressed: () => open(context), child: const Text('open')),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  final trips = [TripSummary(1, "Cox's Bazar", 1240, 'a'), TripSummary(2, 'Sajek Valley', 860, 'b')];

  testWidgets('the trip list picks a trip, all trips, or edits one on a long press', (tester) async {
    final picked = <int?>[];
    final edited = <String>[];
    void open(BuildContext context) => showTripSheet(context,
        trips: trips, selected: 2, onPick: picked.add, onEdit: (t) => edited.add(t.name));

    await _page(tester, open);
    expect(find.text('1240 photos'), findsOneWidget);
    // The trip being shown is the one ticked.
    expect(
        find.descendant(of: find.widgetWithText(ListTile, 'Sajek Valley'), matching: find.byIcon(Icons.check_rounded)),
        findsOneWidget);
    await tester.tap(find.text("Cox's Bazar"));
    await tester.pumpAndSettle();
    expect(picked, [1]);
    expect(find.text('Trip'), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All trips'));
    await tester.pumpAndSettle();
    expect(picked, [1, null]);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Sajek Valley'));
    await tester.pumpAndSettle();
    expect(edited, ['Sajek Valley']);
    expect(picked, [1, null]);
  });

  testWidgets('the who list filters by gender and group, and makes groups', (tester) async {
    final genders = <Gender?>[];
    final groups = <int?>[];
    var made = 0;
    final editedGroups = <String>[];
    void open(BuildContext context) => showWhoSheet(
          context,
          everyone: 24,
          genders: const {Gender.male: 11, Gender.female: 13},
          gender: null,
          groups: [
            PersonGroup(1, 'Uni friends', {1, 2, 3}),
            PersonGroup(2, 'Family', {4}),
          ],
          groupId: 2,
          onGender: genders.add,
          onGroup: groups.add,
          onNewGroup: () => made++,
          onEditGroup: (g) => editedGroups.add(g.name),
        );

    await _page(tester, open);
    expect(find.text('3 people'), findsOneWidget);
    expect(find.text('1 person'), findsOneWidget);
    await tester.tap(find.textContaining('Women'));
    await tester.pumpAndSettle();
    expect(genders, [Gender.female]);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uni friends'));
    await tester.pumpAndSettle();
    expect(groups, [1]);

    // Tapping the group already shown goes back to everyone.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    expect(groups, [1, null]);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Family'));
    await tester.pumpAndSettle();
    expect(editedGroups, ['Family']);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New group'));
    await tester.pumpAndSettle();
    expect(made, 1);
  });

  testWidgets('the who list leaves out men and women until someone is known to be either', (tester) async {
    void open(BuildContext context) => showWhoSheet(
          context,
          everyone: 3,
          genders: const {},
          gender: null,
          groups: const [],
          groupId: null,
          onGender: (_) {},
          onGroup: (_) {},
          onNewGroup: () {},
          onEditGroup: (_) {},
        );

    await _page(tester, open);
    expect(find.textContaining('Women'), findsNothing);
    expect(find.text('New group'), findsOneWidget);
  });

  testWidgets('the view list offers every layout and returns the one tapped', (tester) async {
    PeopleLayout? picked;
    Future<void> open(BuildContext context) async => picked = await showViewSheet(context, PeopleLayout.grid);

    await _page(tester, open);
    for (final l in PeopleLayout.values) {
      expect(find.text(l.label), findsOneWidget);
    }
    await tester.tap(find.text('Globe'));
    await tester.pumpAndSettle();
    expect(picked, PeopleLayout.globe);
  });

  testWidgets('a menu chip shows its arrow, and an icon chip taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          const CapsuleChip(label: 'All trips', menu: true),
          const CapsuleChip(label: 'Plain'),
          IconChip(icon: Icons.calendar_month_rounded, tooltip: 'Any date', onTap: () => taps++),
        ]),
      ),
    ));
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
    await tester.tap(find.byTooltip('Any date'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });
}
