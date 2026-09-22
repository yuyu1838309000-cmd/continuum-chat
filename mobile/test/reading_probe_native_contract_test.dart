import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final appGradleSource = File(
    'android/app/build.gradle.kts',
  ).readAsStringSync();
  final appProguardRules = File(
    'android/app/proguard-rules.pro',
  ).readAsStringSync();
  final serviceSource = File(
    'android/app/src/main/kotlin/dev/continuum/chat/'
    'PermissionAccessibilityService.kt',
  ).readAsStringSync();

  test('native reading probe only captures the two supported reader apps', () {
    final allowlistBody = RegExp(
      r'READING_PROBE_PACKAGES = setOf\((.*?)\n\s*\)',
      dotAll: true,
    ).firstMatch(serviceSource)?.group(1);
    final packages = RegExp(
      r'"([^"]+)"',
    ).allMatches(allowlistBody ?? '').map((match) => match.group(1)).toSet();

    expect(packages, {'com.jjwxc.reader', 'net.cpwxx.cpfiction'});
    expect(
      serviceSource,
      contains('if (pkg !in READING_PROBE_PACKAGES) return'),
    );
    expect(serviceSource, contains('eventPackage !in READING_PROBE_PACKAGES'));
  });

  test('native reading probe rate-limits capture in addition to debounce', () {
    final intervalMatch = RegExp(
      r'PROBE_MIN_CAPTURE_INTERVAL_MS = ([\d_]+)L',
    ).firstMatch(serviceSource);
    expect(intervalMatch, isNotNull);

    final interval = int.parse(intervalMatch!.group(1)!.replaceAll('_', ''));
    expect(interval, inInclusiveRange(2000, 5000));
    expect(serviceSource, contains('PROBE_DEBOUNCE_MS'));
    expect(serviceSource, contains('lastProbeCaptureStartedAtByPackage'));
  });

  test('Changpei fallback is a single UsageStats package-gated poll', () {
    final pollIntervalMatch = RegExp(
      r'CHANGPEI_PROBE_POLL_INTERVAL_MS = ([\d_]+)L',
    ).firstMatch(serviceSource);
    expect(pollIntervalMatch, isNotNull);

    final interval = int.parse(
      pollIntervalMatch!.group(1)!.replaceAll('_', ''),
    );
    expect(interval, inInclusiveRange(3000, 5000));
    expect(serviceSource, contains('pendingChangpeiPollRunnable != null'));
    expect(
      serviceSource,
      contains('if (foreground.packageName != CHANGPEI_PACKAGE) return'),
    );
    expect(
      serviceSource,
      contains(
        'probeHandler.postDelayed(task, CHANGPEI_PROBE_POLL_INTERVAL_MS)',
      ),
    );
    expect(serviceSource, contains('sourceLabel = PROBE_SOURCE_POLL'));
    expect(serviceSource, contains('put("capture_source", sourceLabel)'));

    final pollBody = RegExp(
      r'private fun pollChangpeiReadingProbe\(\) \{(.*?)'
      r'\n    \}\n\n    private fun scheduleReadingProbeCapture',
      dotAll: true,
    ).firstMatch(serviceSource)?.group(1);
    expect(pollBody, isNotNull);
    expect(pollBody, isNot(contains('rootInActiveWindow')));
    expect(pollBody, isNot(contains('activeRootPackage()')));
    expect(pollBody, contains('recentForegroundPackage()'));
    expect(pollBody, contains('verifyRootBeforeScreenshot = false'));
  });

  test('UsageStats foreground lookup is permission-aware and diagnostic', () {
    expect(serviceSource, contains('UsageStatsManager'));
    expect(serviceSource, contains('manager.queryEvents('));
    expect(serviceSource, contains('UsageEvents.Event.ACTIVITY_RESUMED'));
    expect(serviceSource, contains('UsageEvents.Event.MOVE_TO_FOREGROUND'));
    expect(serviceSource, contains('AppOpsManager.OPSTR_GET_USAGE_STATS'));
    expect(serviceSource, contains('"usage_stats_denied"'));
    expect(serviceSource, contains('"usage_stats_no_result"'));
    expect(serviceSource, contains('recordPollDiagnostic('));
    expect(serviceSource, contains('foreground.packageName'));
  });

  test('unchanged Changpei screenshots skip preview writes and OCR', () {
    final duplicateGuard = RegExp(
      r'lastValidScreenshotFingerprintByPackage\[eventPackage\] == '
      r'changpeiScreenshotFingerprint.*?bitmap\.recycle\(\).*?'
      r'finishProbeCapture\(captureToken\).*?return',
      dotAll: true,
    );
    final duplicateGuardMatch = duplicateGuard.firstMatch(serviceSource);
    expect(duplicateGuardMatch, isNotNull);

    final guardOffset = duplicateGuardMatch!.start;
    expect(
      serviceSource.indexOf(
        'saveReadingProbePreview(eventPackage, bitmap)',
        guardOffset,
      ),
      greaterThan(duplicateGuardMatch.end),
    );
    expect(
      serviceSource.indexOf('TextRecognition.getClient(', guardOffset),
      greaterThan(duplicateGuardMatch.end),
    );
    expect(
      serviceSource,
      contains('Bitmap.createScaledBitmap(bitmap, 96, 96, false)'),
    );
  });

  test('poll and event paths share one in-flight capture guard', () {
    expect(serviceSource, contains('if (probeCaptureInFlight) return'));
    expect(serviceSource, contains('val captureToken = beginProbeCapture()'));
    expect(serviceSource, contains('probeCaptureInFlight = true'));
    expect(
      serviceSource,
      contains('val callbackPackage = if (sourceLabel == PROBE_SOURCE_POLL)'),
    );
    expect(
      serviceSource,
      contains('if (callbackPackage != verifiedRootPackage)'),
    );

    final callbackGate = RegExp(
      r'val callbackPackage = if \(sourceLabel == PROBE_SOURCE_POLL\) \{'
      r'(.*?)\n        \} else \{(.*?)\n        \}',
      dotAll: true,
    ).firstMatch(serviceSource);
    expect(callbackGate, isNotNull);
    expect(callbackGate!.group(1), contains('recentForegroundPackage()'));
    expect(callbackGate.group(1), isNot(contains('activeRootPackage()')));
    expect(callbackGate.group(2), contains('activeRootPackage()'));
  });

  test('Jinjiang event capture keeps both active-root gates', () {
    final eventSnapshotBody = RegExp(
      r'private fun captureReadingProbeSnapshot\((.*?)'
      r'\n    \}\n\n    private data class ProbeNodeStats',
      dotAll: true,
    ).firstMatch(serviceSource)?.group(1);
    expect(eventSnapshotBody, isNotNull);
    expect(eventSnapshotBody, contains('val root = rootInActiveWindow'));
    expect(eventSnapshotBody, contains('if (rootPackage != eventPackage)'));
    expect(
      serviceSource,
      contains(
        'val requestRootPackage = if (verifyRootBeforeScreenshot) '
        'activeRootPackage() else verifiedRootPackage',
      ),
    );
  });

  test('probe diagnostic is session-scoped and does not grow failures', () {
    final storeSource = File(
      'android/app/src/main/kotlin/dev/continuum/chat/'
      'ReadingProbeStore.kt',
    ).readAsStringSync();
    final diagnosticBody = RegExp(
      r'fun recordPollDiagnostic\((.*?)\n    \}\n\n    fun clearDiagnostic',
      dotAll: true,
    ).firstMatch(storeSource)?.group(1);

    expect(diagnosticBody, isNotNull);
    expect(diagnosticBody, contains('putString(KEY_DIAGNOSTIC'));
    expect(diagnosticBody, isNot(contains('KEY_FAILURES')));
    expect(storeSource, contains('put("poll_foreground_package"'));
    expect(
      storeSource,
      contains('put("probe_diagnostic_ts", diagnostic.optLong("ts"))'),
    );
    expect(storeSource, contains('.remove(KEY_DIAGNOSTIC)'));
    expect(serviceSource, contains('ReadingProbeStore.clearDiagnostic(this)'));
  });

  test('poll heartbeat is recorded before an in-flight capture returns', () {
    final pollBody = RegExp(
      r'private fun pollChangpeiReadingProbe\(\) \{(.*?)'
      r'\n    \}\n\n    private fun scheduleReadingProbeCapture',
      dotAll: true,
    ).firstMatch(serviceSource)?.group(1);

    expect(pollBody, isNotNull);
    expect(
      pollBody!.indexOf('ReadingProbeStore.recordPollDiagnostic('),
      lessThan(pollBody.indexOf('if (probeCaptureInFlight) return')),
    );
  });

  test('native OCR and screenshot resources have bounded lifetimes', () {
    expect(serviceSource, isNot(contains('probeTextRecognizer')));
    expect(serviceSource, contains('recognizer.close()'));
    expect(serviceSource, contains('bitmap.recycle()'));
    expect(serviceSource, contains('buffer.close()'));
    expect(serviceSource, contains('finishProbeCapture(captureToken)'));
  });

  test('disabling the probe clears delayed work and cooldown state', () {
    expect(
      serviceSource,
      contains(
        'pendingProbeCallbacks.forEach { probeHandler.removeCallbacks(it) }',
      ),
    );
    expect(serviceSource, contains('pendingProbeCallbacks.clear()'));
    expect(serviceSource, contains('pendingChangpeiPollRunnable = null'));
    expect(
      serviceSource,
      contains('lastProbeCaptureStartedAtByPackage.clear()'),
    );
    expect(
      serviceSource,
      contains('lastValidScreenshotFingerprintByPackage.clear()'),
    );
    expect(
      serviceSource,
      matches(
        RegExp(
          r'override fun onDestroy\(\).*?resetReadingProbeSession\(\)',
          dotAll: true,
        ),
      ),
    );
  });

  test('release R8 uses the app ProGuard rules', () {
    expect(
      appGradleSource,
      matches(
        RegExp(
          r'buildTypes\s*\{.*release\s*\{.*proguardFiles\s*\('
          r'.*getDefaultProguardFile\("proguard-android-optimize\.txt"\)'
          r'.*"proguard-rules\.pro"',
          dotAll: true,
        ),
      ),
    );
  });

  test('R8 keeps reflected Firebase and ML Kit registrar constructors', () {
    expect(
      appProguardRules,
      matches(
        RegExp(
          r'-keep\s+class\s+\*\s+implements\s+'
          r'com\.google\.firebase\.components\.ComponentRegistrar\s*\{'
          r'\s*public\s+<init>\(\);\s*\}',
          dotAll: true,
        ),
      ),
    );
    expect(appProguardRules, isNot(contains('-dontshrink')));
    expect(appProguardRules, isNot(contains('-dontoptimize')));
    expect(appProguardRules, isNot(contains('-dontobfuscate')));
  });
}
