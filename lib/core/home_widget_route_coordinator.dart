// Production coordinator owning deferred/pending home-widget launch routes.
//
// PlanFlowApp delegates the whole pending-route lifecycle to this class:
// deferral while Supabase/auth/startup readiness is unresolved, the single
// navigation attempt, bounded arrival verification, and — critically — the
// NEW contract that a giving-up outcome RETAINS the pending target (date /
// voice autoStart query included) and never consumes the native intent.
// Only a confirmed arrival consumes.
//
// Everything environment-specific is injected:
//   * readinessResolver : is the destination allowed right now?
//   * wakeSignal        : Listenable whose notifications re-evaluate deferral
//   * navigate          : perform the actual navigation (go/push/seed home)
//   * currentUri        : read the router's current location
//   * consume           : native intent consumption (confirmed-only)
//   * onDeferred / onTerminal : app-owned policy hooks (login redirect,
//                         startup-gate release, diagnostics)
//
// Integration tests drive the SAME coordinator with a fake readiness and the
// real router/screens; no QA replica exists.
//
// Guarantees:
//   * exactly-once navigation per cycle (wake events during verification are
//     ignored; no duplicate apply continuations)
//   * bounded event-driven waiting (readinessTimeout, arrival check
//     attempts, capped navigation cycles) — no hot polling loop
//   * timeout NEVER means success: it moves the pending target to the
//     retained phase without consuming anything
//   * timers/listeners are cleaned up on cancel/dispose

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Whether the pending destination may be navigated to right now.
enum HomeWidgetRouteReadiness {
  /// Keep deferring silently (splash, Supabase init, auth still resolving).
  notReady,

  /// Session resolved but signed out. The app owns the login redirect; the
  /// pending route stays deferred until sign-in completes (no suppression
  /// bypass to a protected screen).
  needsAuth,

  /// Supabase ready + initial session resolved + signed in (+ any extra
  /// setup guards the app folds into its resolver).
  ready,
}

/// Lifecycle phase of the active pending route.
enum HomeWidgetRoutePhase {
  idle,
  waitingReadiness,
  verifyingArrival,
  retained,
  confirmed,
}

/// Terminal outcome of one [HomeWidgetRouteCoordinator.submitRoute] call.
enum HomeWidgetRouteOutcome {
  /// Arrival verified (path + query). Native intent consumed exactly once.
  confirmed,

  /// Arrival never verified within bounds. Pending target is RETAINED for a
  /// later event-driven retry; the native intent is NOT consumed.
  givingUp,

  /// Superseded by a newer submission, or cancelled/disposed.
  cancelled,
}

/// Result of one arrival check attempt.
@visibleForTesting
enum HomeWidgetArrivalCheckResult { confirmed, retrying, givingUp }

/// NEW contract: only a confirmed arrival consumes the native intent.
/// [HomeWidgetArrivalCheckResult.givingUp] retains the pending target and
/// must NOT consume (old P5R consume-on-givingUp is intentionally replaced;
/// a timeout must never mean success).
@visibleForTesting
bool shouldConsumeHomeWidgetLaunch(HomeWidgetArrivalCheckResult result) {
  return result == HomeWidgetArrivalCheckResult.confirmed;
}

/// Pure arrival-check classifier: [arrived] at [attempt] of [maxAttempts].
@visibleForTesting
HomeWidgetArrivalCheckResult resolveHomeWidgetArrivalCheckResult({
  required bool arrived,
  required int attempt,
  required int maxAttempts,
}) {
  if (arrived) {
    return HomeWidgetArrivalCheckResult.confirmed;
  }
  return attempt < maxAttempts
      ? HomeWidgetArrivalCheckResult.retrying
      : HomeWidgetArrivalCheckResult.givingUp;
}

/// Order-independent semantic comparison of two query maps. Arrival is only
/// confirmed when the selected date / autoStart flag exactly matches; a
/// wrong-date landing stays unconfirmed.
@visibleForTesting
bool queryParametersEqual(
  Map<String, String> a,
  Map<String, String> b,
) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

/// Default arrival predicate: same path AND same query parameters.
bool defaultHomeWidgetRouteMatches(Uri current, Uri expected) {
  return current.path == expected.path &&
      queryParametersEqual(current.queryParameters, expected.queryParameters);
}

/// Callback signatures for the injected seam.
typedef HomeWidgetRouteReadinessResolver = HomeWidgetRouteReadiness Function();
typedef HomeWidgetRouteNavigate = void Function(String route);
typedef HomeWidgetRouteCurrentUri = Uri Function();
typedef HomeWidgetRouteConsume = Future<void> Function(String route);
typedef HomeWidgetRouteDeferred = void Function(
  String route,
  HomeWidgetRouteReadiness readiness,
);
typedef HomeWidgetRouteTerminal = void Function(
  String route,
  HomeWidgetRouteOutcome outcome,
);

/// Owns the pending widget-launch route: deferral, single navigation,
/// bounded arrival verification, confirmed-only consumption, and giving-up
/// retention with capped event-driven retries.
class HomeWidgetRouteCoordinator {
  HomeWidgetRouteCoordinator({
    required this.readinessResolver,
    this.wakeSignal,
    required this.navigate,
    required this.currentUri,
    this.consume,
    this.onDeferred,
    this.onTerminal,
    this.routeMatches = defaultHomeWidgetRouteMatches,
    this.readinessTimeout = const Duration(seconds: 15),
    this.arrivalCheckInterval = const Duration(milliseconds: 120),
    this.arrivalMaxAttempts = 10,
    this.retainedRetryDelay = const Duration(seconds: 2),
    this.maxNavigationCycles = 3,
    this.maxBudgetGrants = 3,
  });

  /// Full readiness evaluation owned by the app (Supabase, auth session,
  /// sign-in, extra setup guards).
  final HomeWidgetRouteReadinessResolver readinessResolver;

  /// Change notifications that re-evaluate a deferred/retained route.
  final Listenable? wakeSignal;

  /// Performs the actual navigation for the pending route.
  final HomeWidgetRouteNavigate navigate;

  /// Reads the router's current location for arrival checks.
  final HomeWidgetRouteCurrentUri currentUri;

  /// Native intent consumption. Invoked exactly once per confirmed arrival.
  final HomeWidgetRouteConsume? consume;

  /// Called each time a pending route is deferred, with the blocking
  /// readiness (e.g. the app redirects to login on [needsAuth]).
  final HomeWidgetRouteDeferred? onDeferred;

  /// Called when a pending route reaches a terminal outcome for its current
  /// cycle: confirmed, givingUp (retained), or cancelled.
  final HomeWidgetRouteTerminal? onTerminal;

  /// Arrival predicate (path + exact query match by default).
  final bool Function(Uri current, Uri expected) routeMatches;

  /// Upper bound for one continuous readiness-waiting episode. A timeout
  /// moves the route to [HomeWidgetRoutePhase.retained]; it never consumes.
  final Duration readinessTimeout;

  /// Delay between arrival checks (bounded by [arrivalMaxAttempts]).
  final Duration arrivalCheckInterval;

  /// Arrival checks per navigation cycle.
  final int arrivalMaxAttempts;

  /// Bounded idle watchdog after a givingUp: one delayed re-evaluation per
  /// retention, up to [maxNavigationCycles] navigation cycles in total.
  final Duration retainedRetryDelay;

  /// Hard cap on navigation executions per submitted route (first
  /// navigation + retained retries). Beyond the cap the route stays
  /// retained and only a new submission/cancel changes it.
  final int maxNavigationCycles;

  /// Max number of extra one-cycle navigation budgets per submitted route
  /// that an explicit [kickPendingRoute] or a genuine not-ready -> ready
  /// transition may grant once the cap is hit. Absolute bound; generic wake
  /// storms never grant budget.
  final int maxBudgetGrants;

  String? _pendingRoute;
  int _generation = 0;
  int _navigationCycles = 0;
  HomeWidgetRoutePhase _phase = HomeWidgetRoutePhase.idle;
  Timer? _timer;
  Completer<HomeWidgetRouteOutcome>? _outcome;
  bool _wakeAttached = false;
  int _budgetGrants = 0;
  bool _wasReady = false;
  bool _readinessTimedOut = false;
  bool _inTerminalCallback = false;

  /// The pending route target, retained across deferral and giving-up.
  String? get pendingRoute => _pendingRoute;

  /// Whether a pending target exists (deferred, verifying, or retained).
  bool get hasPendingRoute => _pendingRoute != null;

  /// Current lifecycle phase of the pending route.
  HomeWidgetRoutePhase get phase => _phase;

  /// Monotonic generation; bumped by every new submission/cancel.
  int get generation => _generation;

  /// Whether a readiness wait or retention is currently armed.
  @visibleForTesting
  bool get isWaiting =>
      _phase == HomeWidgetRoutePhase.waitingReadiness ||
      _phase == HomeWidgetRoutePhase.retained;

  /// Submits a new pending route target. A previous pending target (any
  /// phase) is superseded: its outcome completes with
  /// [HomeWidgetRouteOutcome.cancelled] and the new generation takes over.
  ///
  /// Returns the outcome future for THIS submission.
  Future<HomeWidgetRouteOutcome> submitRoute(String route) {
    assert(route.trim().isNotEmpty, 'pending route must be non-empty');
    _supersede();
    final generation = ++_generation;
    _pendingRoute = route;
    _navigationCycles = 0;
    _budgetGrants = 0;
    _wasReady = false;
    _readinessTimedOut = false;
    final completer = Completer<HomeWidgetRouteOutcome>();
    _outcome = completer;
    // A brand-new submission starts as a deferred/waiting route. _evaluate
    // only acts on waitingReadiness/retained phases, so without this the
    // very first evaluation (fresh state == idle) would short-circuit and
    // the route would never defer, navigate, or time out.
    _phase = HomeWidgetRoutePhase.waitingReadiness;
    _evaluate(generation);
    return completer.future;
  }

  /// Event-driven kick for a retained/waiting route (e.g. app foreground
  /// resume or an explicit retry request). Ignored in other phases.
  ///
  /// When the navigation cap has been reached this grants (at most
  /// [maxBudgetGrants] times per submission) one more navigation cycle.
  void kickPendingRoute() {
    if (_pendingRoute != null &&
        _phase == HomeWidgetRoutePhase.retained &&
        _navigationCycles >= maxNavigationCycles) {
      _grantBudget();
    }
    _evaluate(_generation);
  }

  /// Location-change hint (e.g. router location listener). Never navigates
  /// and never grants budget: it can only CONFIRM a retained route whose
  /// exact path + query is now current while the app is ready.
  void notifyLocationChanged() {
    final route = _pendingRoute;
    if (route == null || _inTerminalCallback) {
      return;
    }
    if (_phase != HomeWidgetRoutePhase.retained) {
      return;
    }
    if (readinessResolver() != HomeWidgetRouteReadiness.ready) {
      return;
    }
    if (routeMatches(currentUri(), Uri.parse(route))) {
      _evaluate(_generation);
    }
  }

  void _grantBudget() {
    if (_budgetGrants >= maxBudgetGrants) {
      return;
    }
    _budgetGrants++;
    _navigationCycles = maxNavigationCycles > 0 ? maxNavigationCycles - 1 : 0;
  }

  void _notifyTerminal(String route, HomeWidgetRouteOutcome outcome) {
    final callback = onTerminal;
    if (callback == null) {
      return;
    }
    // The app's terminal hook may notify the very listenable we watch (gate
    // release). Ignore those self-notifications so they cannot re-enter.
    final previous = _inTerminalCallback;
    _inTerminalCallback = true;
    try {
      callback(route, outcome);
    } finally {
      _inTerminalCallback = previous;
    }
  }

  /// Clears the pending target without consuming anything.
  void cancel() {
    if (_pendingRoute == null && _phase == HomeWidgetRoutePhase.idle) {
      return;
    }
    final route = _pendingRoute;
    _teardownTimerAndWake();
    _completeOutcome(HomeWidgetRouteOutcome.cancelled);
    if (route != null) {
      onTerminal?.call(route, HomeWidgetRouteOutcome.cancelled);
    }
    _pendingRoute = null;
    _phase = HomeWidgetRoutePhase.idle;
    _generation++;
  }

  /// Removes all timers and listeners. The coordinator must not be reused.
  @mustCallSuper
  void dispose() {
    _teardownTimerAndWake();
    _completeOutcome(HomeWidgetRouteOutcome.cancelled);
    _pendingRoute = null;
    _phase = HomeWidgetRoutePhase.idle;
    _generation++;
  }

  // ------------------------------------------------------------------

  /// Completes the current submission's outcome future exactly once.
  /// Retention cycles can reach a terminal branch more than once for the
  /// same completer (e.g. givingUp, wake, give up again); every completion
  /// after the first is a no-op so the future never double-completes.
  void _completeOutcome(HomeWidgetRouteOutcome outcome) {
    final completer = _outcome;
    if (completer == null || completer.isCompleted) {
      return;
    }
    completer.complete(outcome);
  }

  void _supersede() {
    _teardownTimerAndWake();
    _completeOutcome(HomeWidgetRouteOutcome.cancelled);
  }

  void _evaluate(int generation) {
    if (generation != _generation) {
      return;
    }
    final route = _pendingRoute;
    if (route == null) {
      return;
    }
    if (_phase != HomeWidgetRoutePhase.waitingReadiness &&
        _phase != HomeWidgetRoutePhase.retained) {
      // Exactly-once navigation: wake events during verification must not
      // re-enter navigation, and idle/confirmed routes have no pending work.
      return;
    }
    final readiness = readinessResolver();
    switch (readiness) {
      case HomeWidgetRouteReadiness.ready:
        final transitioned = !_wasReady;
        _wasReady = true;
        if (_navigationCycles >= maxNavigationCycles && transitioned) {
          // Genuine not-ready -> ready transition: bounded new budget.
          _grantBudget();
        }
        if (_navigationCycles >= maxNavigationCycles &&
            !routeMatches(currentUri(), Uri.parse(route))) {
          // Cap reached and not at the exact target: stay retained, purely
          // event-driven. (An exact late arrival still confirms below.)
          _phase = HomeWidgetRoutePhase.retained;
          _ensureWakeListener();
          return;
        }
        _beginNavigation(generation, route);
        break;
      case HomeWidgetRouteReadiness.notReady:
      case HomeWidgetRouteReadiness.needsAuth:
        _wasReady = false;
        onDeferred?.call(route, readiness);
        if (generation != _generation) {
          return;
        }
        if (_readinessTimedOut && _phase == HomeWidgetRoutePhase.retained) {
          // Already timed out and gate released: stay retained without
          // restarting the timeout (no 15s re-arm loop).
          _ensureWakeListener();
          return;
        }
        _enterWaiting(generation);
        break;
    }
  }

  void _enterWaiting(int generation) {
    if (generation != _generation) {
      return;
    }
    _phase = HomeWidgetRoutePhase.waitingReadiness;
    _ensureWakeListener();
    // Restart the bounded episode timeout on every deferral evaluation.
    _timer?.cancel();
    _timer = Timer(readinessTimeout, () {
      // Timeout NEVER consumes: drop to retained; wake events can resume.
      if (_generation == generation &&
          _phase == HomeWidgetRoutePhase.waitingReadiness) {
        _phase = HomeWidgetRoutePhase.retained;
        _readinessTimedOut = true;
        _ensureWakeListener();
        _timer?.cancel();
        _timer = null;
        final route = _pendingRoute;
        if (route != null) {
          // Release the app's startup gate (no consume, pending retained).
          // The submit future stays pending (compat): a later confirmation
          // can still complete it as confirmed.
          _notifyTerminal(route, HomeWidgetRouteOutcome.givingUp);
        }
      }
    });
  }

  void _beginNavigation(int generation, String route) {
    if (generation != _generation) {
      return;
    }
    _timer?.cancel();
    _readinessTimedOut = false;
    final expected = Uri.parse(route);
    final alreadyThere = routeMatches(currentUri(), expected);
    // Enter verification BEFORE the app's navigate callback: that callback
    // raises the widget hold, which notifies the wake signal; a still-retained
    // phase would re-enter _evaluate and navigate the same target twice.
    _phase = HomeWidgetRoutePhase.verifyingArrival;
    if (!alreadyThere) {
      _navigationCycles++;
      navigate(route);
    }
    if (generation != _generation) {
      return;
    }
    _scheduleArrivalCheck(generation, attempt: 0);
  }

  void _scheduleArrivalCheck(int generation, {required int attempt}) {
    if (generation != _generation) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(arrivalCheckInterval, () {
      _checkArrival(generation, attempt: attempt);
    });
  }

  void _checkArrival(int generation, {required int attempt}) {
    if (generation != _generation) {
      return;
    }
    final route = _pendingRoute;
    if (route == null) {
      return;
    }
    final arrived = routeMatches(currentUri(), Uri.parse(route));
    final result = resolveHomeWidgetArrivalCheckResult(
      arrived: arrived,
      attempt: attempt,
      maxAttempts: arrivalMaxAttempts,
    );
    switch (result) {
      case HomeWidgetArrivalCheckResult.confirmed:
        _completeConfirmed(generation, route);
        break;
      case HomeWidgetArrivalCheckResult.retrying:
        _scheduleArrivalCheck(generation, attempt: attempt + 1);
        break;
      case HomeWidgetArrivalCheckResult.givingUp:
        _retainAfterGivingUp(generation, route);
        break;
    }
  }

  void _completeConfirmed(int generation, String route) {
    if (generation != _generation) {
      return;
    }
    _teardownTimerAndWake();
    _pendingRoute = null;
    _phase = HomeWidgetRoutePhase.confirmed;
    _completeOutcome(HomeWidgetRouteOutcome.confirmed);
    final callback = consume;
    if (callback != null) {
      // Exactly once, confirmed-only; never block the caller on native.
      unawaited(
        Future<void>.sync(() => callback(route)).catchError((Object _) {}),
      );
    }
    _notifyTerminal(route, HomeWidgetRouteOutcome.confirmed);
  }

  void _retainAfterGivingUp(int generation, String route) {
    if (generation != _generation) {
      return;
    }
    _phase = HomeWidgetRoutePhase.retained;
    _ensureWakeListener();
    _timer?.cancel();
    if (_navigationCycles < maxNavigationCycles) {
      // Bounded idle watchdog: exactly one delayed re-evaluation per
      // retention episode; no recurring hot loop.
      _timer = Timer(retainedRetryDelay, () {
        _evaluate(_generation);
      });
    }
    _notifyTerminal(route, HomeWidgetRouteOutcome.givingUp);
    _completeOutcome(HomeWidgetRouteOutcome.givingUp);
  }

  void _handleWake() {
    if (_inTerminalCallback) {
      return;
    }
    _evaluate(_generation);
  }

  void _ensureWakeListener() {
    final signal = wakeSignal;
    if (signal == null || _wakeAttached) {
      return;
    }
    signal.addListener(_handleWake);
    _wakeAttached = true;
  }

  void _teardownTimerAndWake() {
    _timer?.cancel();
    _timer = null;
    final signal = wakeSignal;
    if (signal != null && _wakeAttached) {
      signal.removeListener(_handleWake);
      _wakeAttached = false;
    }
  }
}
