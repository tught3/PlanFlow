import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:planflow/services/update_service.dart';

void main() {
  group('UpdateService', () {
    late FakeUpdateFlowGateway updateFlow;
    late FakeVersionMetadataProvider metadataProvider;
    late FakeUpdateVersionTracker versionTracker;
    late FakePlayStoreLauncher playStoreLauncher;
    late FakePostUpdateHook postUpdateHook;

    setUp(() {
      UpdateService.resetForTest();
      updateFlow = FakeUpdateFlowGateway();
      metadataProvider = const FakeVersionMetadataProvider(
        buildNumber: 120,
        packageName: 'com.planflow.app',
      );
      versionTracker = FakeUpdateVersionTracker();
      playStoreLauncher = FakePlayStoreLauncher();
      postUpdateHook = FakePostUpdateHook();
    });

    tearDown(() {
      UpdateService.resetForTest();
    });

    test('runs post-update hook when version increased', () async {
      versionTracker.stored = 100;
      updateFlow.result = const UpdateCheckResult(
        updateAvailability: UpdateAvailabilityState.unavailable,
        immediateUpdateAllowed: false,
        flexibleUpdateAllowed: false,
      );
      UpdateService.instance = UpdateService(
        updateFlow: updateFlow,
        versionMetadataProvider: metadataProvider,
        versionTracker: versionTracker,
        playStoreLauncher: playStoreLauncher,
        postUpdateHook: postUpdateHook,
        minRequiredVersionProvider: () => 200,
        skipInDebug: false,
      );

      await UpdateService.checkAndPrompt();

      expect(postUpdateHook.runCount, 1);
      expect(versionTracker.stored, 120);
    });

    test('does not rerun post-update hook when version unchanged', () async {
      versionTracker.stored = 120;
      updateFlow.result = const UpdateCheckResult(
        updateAvailability: UpdateAvailabilityState.unavailable,
        immediateUpdateAllowed: false,
        flexibleUpdateAllowed: false,
      );
      UpdateService.instance = UpdateService(
        updateFlow: updateFlow,
        versionMetadataProvider: metadataProvider,
        versionTracker: versionTracker,
        playStoreLauncher: playStoreLauncher,
        postUpdateHook: postUpdateHook,
        minRequiredVersionProvider: () => 200,
        skipInDebug: false,
      );

      await UpdateService.checkAndPrompt();

      expect(postUpdateHook.runCount, 0);
      expect(versionTracker.stored, 120);
    });

    test('uses immediate update for forced update when available', () async {
      versionTracker.stored = 200;
      updateFlow.result = const UpdateCheckResult(
        updateAvailability: UpdateAvailabilityState.available,
        immediateUpdateAllowed: true,
        flexibleUpdateAllowed: true,
      );
      UpdateService.instance = UpdateService(
        updateFlow: updateFlow,
        versionMetadataProvider: metadataProvider,
        versionTracker: versionTracker,
        playStoreLauncher: playStoreLauncher,
        postUpdateHook: postUpdateHook,
        minRequiredVersionProvider: () => 200,
        skipInDebug: false,
      );

      await UpdateService.checkAndPrompt();

      expect(updateFlow.immediateCallCount, 1);
      expect(updateFlow.flexibleStartCallCount, 0);
      expect(updateFlow.flexibleCompleteCallCount, 0);
      expect(playStoreLauncher.openedPackages, isEmpty);
    });

    test('uses flexible update for optional update when allowed', () async {
      versionTracker.stored = 200;
      updateFlow.result = const UpdateCheckResult(
        updateAvailability: UpdateAvailabilityState.available,
        immediateUpdateAllowed: true,
        flexibleUpdateAllowed: true,
      );
      UpdateService.instance = UpdateService(
        updateFlow: updateFlow,
        versionMetadataProvider: metadataProvider,
        versionTracker: versionTracker,
        playStoreLauncher: playStoreLauncher,
        postUpdateHook: postUpdateHook,
        minRequiredVersionProvider: () => 100,
        skipInDebug: false,
      );

      await UpdateService.checkAndPrompt();

      expect(updateFlow.immediateCallCount, 0);
      expect(updateFlow.flexibleStartCallCount, 1);
      expect(updateFlow.flexibleCompleteCallCount, 1);
      expect(playStoreLauncher.openedPackages, isEmpty);
    });

    test('falls back to Play Store when forced update has no in-app path',
        () async {
      versionTracker.stored = 200;
      updateFlow.result = const UpdateCheckResult(
        updateAvailability: UpdateAvailabilityState.available,
        immediateUpdateAllowed: false,
        flexibleUpdateAllowed: false,
      );
      UpdateService.instance = UpdateService(
        updateFlow: updateFlow,
        versionMetadataProvider: metadataProvider,
        versionTracker: versionTracker,
        playStoreLauncher: playStoreLauncher,
        postUpdateHook: postUpdateHook,
        minRequiredVersionProvider: () => 200,
        skipInDebug: false,
      );

      await UpdateService.checkAndPrompt();

      expect(playStoreLauncher.openedPackages, ['com.planflow.app']);
      expect(postUpdateHook.runCount, 0);
    });

    test('falls back to Play Store when forced update is unavailable',
        () async {
      versionTracker.stored = 200;
      updateFlow.result = const UpdateCheckResult(
        updateAvailability: UpdateAvailabilityState.unavailable,
        immediateUpdateAllowed: false,
        flexibleUpdateAllowed: false,
      );
      UpdateService.instance = UpdateService(
        updateFlow: updateFlow,
        versionMetadataProvider: metadataProvider,
        versionTracker: versionTracker,
        playStoreLauncher: playStoreLauncher,
        postUpdateHook: postUpdateHook,
        minRequiredVersionProvider: () => 200,
        skipInDebug: false,
      );

      await UpdateService.checkAndPrompt();

      expect(playStoreLauncher.openedPackages, ['com.planflow.app']);
    });

    test('falls back to Play Store when forced update check throws', () async {
      versionTracker.stored = 200;
      updateFlow.error = StateError('play services unavailable');
      UpdateService.instance = UpdateService(
        updateFlow: updateFlow,
        versionMetadataProvider: metadataProvider,
        versionTracker: versionTracker,
        playStoreLauncher: playStoreLauncher,
        postUpdateHook: postUpdateHook,
        minRequiredVersionProvider: () => 200,
        skipInDebug: false,
      );

      await UpdateService.checkAndPrompt();

      expect(playStoreLauncher.openedPackages, ['com.planflow.app']);
    });

    test('coalesces overlapping update checks', () async {
      versionTracker.stored = 100;
      updateFlow.result = const UpdateCheckResult(
        updateAvailability: UpdateAvailabilityState.available,
        immediateUpdateAllowed: false,
        flexibleUpdateAllowed: true,
      );
      updateFlow.checkCompleter = Completer<UpdateCheckResult>();
      UpdateService.instance = UpdateService(
        updateFlow: updateFlow,
        versionMetadataProvider: metadataProvider,
        versionTracker: versionTracker,
        playStoreLauncher: playStoreLauncher,
        postUpdateHook: postUpdateHook,
        minRequiredVersionProvider: () => 100,
        skipInDebug: false,
      );

      final first = UpdateService.checkAndPrompt();
      final second = UpdateService.checkAndPrompt();
      await Future<void>.delayed(Duration.zero);

      expect(updateFlow.checkForUpdateCallCount, 1);
      expect(postUpdateHook.runCount, 1);

      updateFlow.checkCompleter!.complete(updateFlow.result);
      await Future.wait(<Future<void>>[first, second]);

      expect(updateFlow.flexibleStartCallCount, 1);
      expect(updateFlow.flexibleCompleteCallCount, 1);
    });
  });
}

class FakeUpdateFlowGateway implements UpdateFlowGateway {
  FakeUpdateFlowGateway();

  UpdateCheckResult result = const UpdateCheckResult(
    updateAvailability: UpdateAvailabilityState.unavailable,
    immediateUpdateAllowed: false,
    flexibleUpdateAllowed: false,
  );
  Object? error;
  Completer<UpdateCheckResult>? checkCompleter;

  int checkForUpdateCallCount = 0;
  int immediateCallCount = 0;
  int flexibleStartCallCount = 0;
  int flexibleCompleteCallCount = 0;

  @override
  Future<UpdateCheckResult> checkForUpdate() async {
    checkForUpdateCallCount += 1;
    final error = this.error;
    if (error != null) {
      throw error;
    }
    final completer = checkCompleter;
    if (completer != null) {
      return completer.future;
    }
    return result;
  }

  @override
  Future<void> performImmediateUpdate() async {
    immediateCallCount += 1;
  }

  @override
  Future<void> startFlexibleUpdate() async {
    flexibleStartCallCount += 1;
  }

  @override
  Future<void> completeFlexibleUpdate() async {
    flexibleCompleteCallCount += 1;
  }
}

class FakeVersionMetadataProvider implements AppVersionMetadataProvider {
  const FakeVersionMetadataProvider({
    required this.buildNumber,
    required this.packageName,
  });

  final int buildNumber;
  final String packageName;

  @override
  Future<AppVersionMetadata?> load() async {
    return AppVersionMetadata(
      buildNumber: buildNumber,
      packageName: packageName,
    );
  }
}

class FakeUpdateVersionTracker implements UpdateVersionTracker {
  int? stored;

  @override
  Future<int?> loadLastSeenVersionCode() async {
    return stored;
  }

  @override
  Future<void> saveLastSeenVersionCode(int code) async {
    stored = code;
  }
}

class FakePlayStoreLauncher implements PlayStoreLauncher {
  final List<String> openedPackages = <String>[];

  @override
  Future<bool> openPlayStoreDetails(String packageName) async {
    openedPackages.add(packageName);
    return true;
  }
}

class FakePostUpdateHook implements UpdatePostUpdateHook {
  int runCount = 0;

  @override
  Future<void> run() async {
    runCount += 1;
  }
}
