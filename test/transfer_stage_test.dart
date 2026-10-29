import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/ui/transfer_view.dart';

void main() {
  for (final phase in TransferPhase.values) {
    testWidgets('transfer stage draws while ${phase.name}', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            TransferStage(
              phase: phase,
              fromName: 'You',
              toName: 'Maya\'s Pixel with a long name',
              filesDone: 3,
              token: (i) => ColoredBox(color: Colors.primaries[i % Colors.primaries.length]),
            ),
            const TransferStats(
              title: 'Sending 12 photos to Maya',
              caption: '3 of 12 arrived',
              progress: 0.25,
              color: Colors.blue,
              stats: [('sent', '12 MB'), ('speed', '4 MB/s'), ('left', '9s')],
            ),
            FileMosaic(count: 60, tile: (_) => const ColoredBox(color: Colors.grey), isDone: (i) => i < 3),
          ]),
        ),
      ));
      // Let the loop and the burst run for a while.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(tester.takeException(), isNull);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
    });
  }
}
