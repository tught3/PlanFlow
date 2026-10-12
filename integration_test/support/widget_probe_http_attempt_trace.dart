/// Metadata-only receipts: no request objects or credentials are retained.
enum WidgetProbeHttpLeg {
  sdkInit,
  delayedAuthCalendarRoute,
  voiceSdk,
  standaloneCalendarSheet,
  voiceFake,
  teardown,
}

class WidgetProbeHttpAttemptReceipt {
  const WidgetProbeHttpAttemptReceipt(
      this.ordinal, this.leg, this.method, this.hostClass, this.pathClass);
  final int ordinal;
  final WidgetProbeHttpLeg leg;
  final String method;
  final String hostClass;
  final String pathClass;

  @override
  String toString() => 'ordinal=$ordinal leg=${leg.name} method=$method '
      'hostClass=$hostClass pathClass=$pathClass';
}

class WidgetProbeHttpAttemptSnapshot {
  const WidgetProbeHttpAttemptSnapshot(this.total, this.leg);
  final int total;
  final WidgetProbeHttpLeg leg;
  int deltaFrom(WidgetProbeHttpAttemptSnapshot earlier) =>
      total - earlier.total;
}

class WidgetProbeHttpAttemptTrace {
  static const maxRecords = 20;
  int _total = 0;
  WidgetProbeHttpLeg leg = WidgetProbeHttpLeg.sdkInit;
  final List<WidgetProbeHttpAttemptReceipt> _records = [];
  int get total => _total;
  List<WidgetProbeHttpAttemptReceipt> get records =>
      List.unmodifiable(_records);
  WidgetProbeHttpAttemptSnapshot snapshot() =>
      WidgetProbeHttpAttemptSnapshot(_total, leg);

  /// Query/fragment/body/headers are neither read nor retained.
  /// Unknown paths are not allowlisted.
  void record({required String method, required Uri uri}) {
    _total++;
    if (_records.length >= maxRecords) return;
    const safeMethods = <String>{
      'GET',
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
      'HEAD',
      'OPTIONS'
    };
    final safeMethod = safeMethods.contains(method) ? method : 'other-redacted';
    final hostClass =
        uri.host.endsWith('.invalid') ? 'qa-invalid' : 'unexpected-host';
    final path = uri.path;
    const knownRestPaths = <String, String>{
      '/rest/v1/group_event_comments': '/rest/v1/group_event_comments',
      '/rest/v1/group_events': '/rest/v1/group_events',
      '/rest/v1/group_members': '/rest/v1/group_members',
      '/rest/v1/groups': '/rest/v1/groups',
    };
    const knownAuthPaths = <String>{
      '/auth/v1/token',
      '/auth/v1/user',
      '/auth/v1/logout',
      '/auth/v1/signup',
      '/auth/v1/settings',
    };
    final pathClass = knownRestPaths[path] ??
        (knownAuthPaths.contains(path) ? path : 'other-redacted');
    _records.add(WidgetProbeHttpAttemptReceipt(
        _total, leg, safeMethod, hostClass, pathClass));
  }
}
