import 'package:flutter/material.dart';

import 'glass.dart';
import 'widgets.dart';

/// Stands in for a tab that needs the phone's photo library, on desktop,
/// until the folder-based desktop library exists (design/windows-port-plan.md).
class DesktopSoon extends StatelessWidget {
  const DesktopSoon({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassScrollView(
        title: title,
        slivers: const [
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyIllustration(message: desktopSoonMessage),
          ),
        ],
      ),
    );
  }
}

/// What desktop users read wherever the photo library would be.
const desktopSoonMessage =
    'Photo scanning on this computer is coming soon.\n'
    'For now, use the Share tab to send and receive photos with your phone.';
