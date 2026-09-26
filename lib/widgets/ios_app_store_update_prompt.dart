import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/app_feedback_service.dart';
import '../services/ios_app_store_update_service.dart';
import '../services/update_service.dart';

/// Asks before opening the App Store and reports launch failures in context.
/// [openStore] and [showFailure] are injectable to keep the interaction
/// verifiable without invoking platform channels in widget tests.
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
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.appUpdateLater),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.appUpdateNow),
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
