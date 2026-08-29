import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current;
  File file(String path) => File('${root.path}${Platform.pathSeparator}$path');

  test('provisional iOS identity is single-sourced and account-gated', () {
    final identity = file('ios/Flutter/PlanFlow-Identity.xcconfig');
    expect(identity.existsSync(), isTrue);
    final text = identity.readAsStringSync();
    expect(
        text,
        contains(
            'PLANFLOW_IOS_IDENTITY_STATUS = PROVISIONAL_ACCOUNT_CONFIRMATION_REQUIRED'));
    expect(text, contains('PLANFLOW_IOS_BUNDLE_ID = com.planflow.app'));
    expect(
        text,
        contains(
            r'PLANFLOW_IOS_WIDGET_BUNDLE_ID = $(PLANFLOW_IOS_BUNDLE_ID).PlanFlowWidget'));
    expect(text, contains('PLANFLOW_IOS_APP_GROUP = group.com.planflow.app'));
  });

  test('Runner and WidgetKit targets are wired without real credentials', () {
    final project =
        file('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(project, contains('PBXNativeTarget "PlanFlowWidgetExtension"'));
    expect(project,
        contains(r'PRODUCT_BUNDLE_IDENTIFIER = "$(PLANFLOW_IOS_BUNDLE_ID)"'));
    expect(
        project,
        contains(
            r'PRODUCT_BUNDLE_IDENTIFIER = "$(PLANFLOW_IOS_WIDGET_BUNDLE_ID)"'));
    expect(project,
        contains('CODE_SIGN_ENTITLEMENTS = Runner/PlanFlow.entitlements'));
    expect(
        project,
        contains(
            'CODE_SIGN_ENTITLEMENTS = PlanFlowWidget/PlanFlowWidget.entitlements'));
    expect(file('ios/Runner/GoogleService-Info.plist').existsSync(), isFalse);
  });

  test('WidgetKit source supports canonical payload, fallback and routes', () {
    final source =
        file('ios/PlanFlowWidget/PlanFlowWidget.swift').readAsStringSync();
    expect(source, contains('widget_schedule_payload_v1'));
    expect(source, contains('schemaVersion'));
    expect(source, contains('isFallback'));
    expect(source, contains('planflow://day/'));
    expect(source, contains('event.route'));
    expect(
        source,
        contains(
            'supportedFamilies([.systemSmall, .systemMedium, .systemLarge])'));
  });

  test('macOS workflow remains fail-closed for native and WidgetKit gates', () {
    final workflow =
        file('.github/workflows/ios-readiness.yml').readAsStringSync();
    expect(workflow, contains('Verify native iOS target contract'));
    expect(workflow, contains('WIDGET_EXTENSION_TARGET_REQUIRED'));
    expect(workflow, contains('flutter build ios --no-codesign'));
    expect(workflow, contains('signed-release:'));
    expect(workflow, contains(r'if: ${{ false }}'));
  });
}
