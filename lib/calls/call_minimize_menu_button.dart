import 'package:flutter/material.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';

/// Takes the user out of the call screen without ending the call.
///
/// Group video calls fill the bottom bar, so the built-in minimize button ends
/// up in the "More" sheet and the page can look like it has no way out. This
/// button lives in the top bar for group calls and pops the call page straight
/// from the root navigator, which is the navigator the prebuilt page was pushed
/// on. The call keeps running behind the floating card that
/// [ZegoUIKitPrebuiltCallMiniOverlayPage] renders.
class CallMinimizeMenuButton extends StatelessWidget {
  const CallMinimizeMenuButton({
    super.key,
    required this.navigatorKey,
  });

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Leave the call screen',
      iconSize: 28,
      color: Colors.white,
      icon: const Icon(Icons.picture_in_picture_alt_rounded),
      onPressed: () => minimizeCallToBackground(
        navigatorKey: navigatorKey,
        fallbackContext: context,
      ),
    );
  }
}

/// Minimizes the running call and removes its page from the screen.
///
/// Returns false when the call was already minimized or the navigator is not
/// available yet. The room is left untouched: the prebuilt page keeps the
/// session because the minimize state is set before the page is popped.
bool minimizeCallToBackground({
  required GlobalKey<NavigatorState>? navigatorKey,
  BuildContext? fallbackContext,
}) {
  final context = navigatorKey?.currentContext ?? fallbackContext;
  if (context == null) return false;

  return ZegoUIKitPrebuiltCallController().minimize.minimize(
        context,
        rootNavigator: true,
      );
}
