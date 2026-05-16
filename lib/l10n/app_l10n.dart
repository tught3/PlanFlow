import 'package:flutter/widgets.dart';

import 'app_localizations.dart';
import 'app_localizations_ko.dart';

export 'app_localizations.dart';

AppLocalizations appL10n(BuildContext context) {
  return Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsKo();
}
