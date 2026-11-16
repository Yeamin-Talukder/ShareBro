import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../data/gallery.dart';
import '../platform/device.dart';
import '../share/nearby.dart';

/// Says in one short sheet why ShareBro needs a permission, right before
/// Android's own prompt. It has one button and it always leads to that
/// prompt, even when closed with back, so it never stands in for the choice.
Future<void> explainPermission(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String body,
}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => PermissionExplainer(icon: icon, title: title, body: body),
    );

/// The explanation itself: icon, title, a sentence or two and one button.
/// In a sheet the button closes it; on a screen it runs [onContinue].
class PermissionExplainer extends StatelessWidget {
  const PermissionExplainer({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.onContinue,
  });

  final IconData icon;
  final String title, body;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: scheme.primary.withAlpha(30), shape: BoxShape.circle),
            child: Icon(icon, size: 32, color: scheme.primary),
          ),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: text.titleLarge),
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center, style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onContinue ?? () => Navigator.pop(context),
              child: const Text('Continue'),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Photo access is off and Android won't ask again: say where to turn it on.
void showAccessBlocked(BuildContext context, String what) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('$what is off. Turn it on in ShareBro\'s settings, under Permissions.'),
    action: SnackBarAction(label: 'Settings', onPressed: openAppSettings),
  ));
}

/// True once ShareBro may read the photo library. Explains why first, then
/// shows Android's prompt; says where to turn it on if that's blocked.
Future<bool> ensurePhotoAccess(BuildContext context) async {
  if (await Gallery.hasAccess()) return true;
  if (!context.mounted) return false;
  await explainPermission(context, icon: Icons.photo_library_rounded, title: photoTitle, body: photoBody);
  if (await Gallery.requestAccess()) return true;
  if (context.mounted) showAccessBlocked(context, 'Photo access');
  return false;
}

/// True once Nearby may run. Explains why first (Android asks for up to
/// five permissions in a row here, which is confusing with no context).
/// [quiet] is for turning on Receive, which works over Wi-Fi without
/// Nearby: it asks at most once per run and doesn't complain if refused.
Future<bool> ensureNearbyAccess(BuildContext context, NearbyLink nearby, {bool quiet = false}) async {
  if (!Device.nearbyNoNetwork) return false; // Android only
  if (await nearby.hasPermissions()) return true;
  if (quiet && _askedQuietly) return false;
  _askedQuietly = true;
  if (!context.mounted) return false;
  await explainPermission(
    context,
    icon: Icons.bluetooth_searching_rounded,
    title: 'Find phones near you',
    body: 'Nearby uses Bluetooth and Wi-Fi to find other phones with ShareBro and send to them '
        'without a Wi-Fi network. Android asks for "Nearby devices" (and location on older phones) for this.',
  );
  if (await nearby.ensurePermissions()) return true;
  if (!quiet && context.mounted) showAccessBlocked(context, 'Nearby access');
  return false;
}

bool _askedQuietly = false;

const photoTitle = 'Allow access to your photos';
const photoBody = 'ShareBro looks at the photos on this phone to find faces and sort your trips. '
    'Your photos stay on the phone unless you send them.';
