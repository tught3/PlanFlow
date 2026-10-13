import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/app_feedback_service.dart';
import '../services/ios_app_store_update_service.dart';
import '../services/update_service.dart';

/// Asks before opening the App Store and reports launch failures in context.
/// [openStore] and [showFailure] are injectable to keep the interaction
/// verifiable without invoking platform channels in widget tests.
///
/// The action area is laid out as a single horizontal Row so a global
/// FilledButton theme with `minimumSize: Size(infinity, 48)` cannot push
/// the update action below the dismiss action inside AlertDialog's
/// OverflowBar. Both buttons are wrapped in [Expanded] with an 8/12 gap
/// and contain [FittedBox] labels to keep each label on one line across
/// narrow viewports and large text scales. Localization, the non-null
/// `barrierDismissible: false` flag, the App Store URI, the optional
/// `openStore` and `showFailure` callbacks, and the fallback to
/// [AppFeedbackService] are preserved verbatim.
Future<void> showIosAppStoreUpdatePrompt({
  required BuildContext context,
  required IosAppStoreUpdate update,
  Future<bool> Function(Uri storeUri)? openStore,
  void Function(BuildContext context, String message)? showFailure,
}) async {
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context);
  final shouldUpdate = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.appUpdateAvailableTitle),
      content: Text('${l10n.appUpdateAvailableMessage}\n${update.version}'),
      actions: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    l10n.appUpdateLater,
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    l10n.appUpdateNow,
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  if (shouldUpdate != true || !context.mounted) return;

  final opened = await (openStore ?? UpdateService.openIosAppStore)(
    update.storeUri,
  );
  if (!opened && context.mounted) {
    final failure = showFailure;
    if (failure != null) {
      failure(context, l10n.appUpdateStoreOpenFailed);
    } else {
      AppFeedbackService.showSnackBar(
        l10n.appUpdateStoreOpenFailed,
        context: context,
      );
    }
  }
}
