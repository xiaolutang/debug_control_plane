// `$$unstable:<reason>` normalization for BF003 cross-language consistency
// tests (fixtures/README.md "归一化标记" section).
//
// Semantic-level fixtures mark fields whose values are environment-dependent
// (`serverHost` / `serverPort` / `localIps` / appMeta injections /
// `error.toString()` ...) with the placeholder string `$$unstable:<reason>`.
// The comparator replaces the ACTUAL wire value at those positions with the
// same placeholder before comparing, so environment drift never fails the
// assertion while shape/type mismatches still do.
//
// Companion implementation:
// `kotlin/src/main/kotlin/com/pantas/debug/controlplane/FixtureNormalize.kt`
// — the two MUST stay logically identical (rules below), otherwise
// cross-language comparison produces false positives.
//
// Rules (single source: fixtures/README.md):
//  1. Keys starting with `_` (e.g. `_fixture_meta`) are fixture
//     self-description metadata — skipped entirely, never compared.
//  2. When the EXPECTED value is the exact string `$$unstable:<reason>`:
//     - the actual value must still be present (non-missing) and, when the
//     reason implies a type, type-compatible (`bound-port` / `sequence` →
//     JSON number; `request-host` / `network-ips` → string / array of
//     string; the rest accept any non-null JSON value);
//     - both sides are then replaced by the placeholder itself.
//  3. Everything else compares for JSON-equality (numbers by num value,
//     booleans, strings, nested objects recursively, arrays element-wise in
//     order).
library;

const String _markerPrefix = '\$\$unstable:';

/// The closed set of `<reason>` values allowed after `$$unstable:`
/// (fixtures/README.md table).
const Set<String> kUnstableReasons = <String>{
  'request-host',
  'bound-port',
  'network-ips',
  'sequence',
  'app-injected',
  'exception-toString',
  'adb-serial',
  'usbmuxd-id',
};

/// Normalize a parsed JSON value: drop `_`-prefixed keys recursively so
/// [normalizedEquals] sees comparable shapes.
Object? normalize(Object? value) {
  if (value is Map<String, Object?>) {
    final out = <String, Object?>{};
    value.forEach((key, v) {
      if (key.startsWith('_')) return;
      out[key] = normalize(v);
    });
    return out;
  }
  if (value is List) {
    return value.map(normalize).toList();
  }
  return value;
}

/// Structural equality on [normalize]d values (order-sensitive arrays).
///
/// Throws [StateError] when an expected marker carries an unknown `<reason>`
/// (the closed set above is part of the fixture contract).
bool normalizedEquals(Object? expected, Object? actual) {
  if (expected is String && expected.startsWith(_markerPrefix)) {
    final reason = expected.substring(_markerPrefix.length);
    if (!kUnstableReasons.contains(reason)) {
      throw StateError(
        'unknown unstable reason "$reason" (allowed: $kUnstableReasons)',
      );
    }
    if (actual == null) return false;
    // Type guards per reason family — mirrors FixtureNormalize.kt.
    switch (reason) {
      case 'bound-port':
      case 'sequence':
        return actual is num;
      case 'request-host':
      case 'exception-toString':
      case 'adb-serial':
      case 'usbmuxd-id':
        return actual is String;
      case 'network-ips':
        return actual is List && actual.every((e) => e is String);
      default:
        return true; // app-injected: any non-null JSON value.
    }
  }
  if (actual is String && actual.startsWith(_markerPrefix)) return false;
  if (expected is Map && actual is Map) {
    final eKeys =
        expected.keys.where((k) => !k.startsWith('_')).toList()..sort();
    final aKeys =
        actual.keys.where((k) => !k.startsWith('_')).toList()..sort();
    if (eKeys.length != aKeys.length) return false;
    for (var i = 0; i < eKeys.length; i++) {
      if (eKeys[i] != aKeys[i]) return false;
      if (!normalizedEquals(expected[eKeys[i]], actual[aKeys[i]])) {
        return false;
      }
    }
    return true;
  }
  if (expected is List && actual is List) {
    if (expected.length != actual.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (!normalizedEquals(expected[i], actual[i])) return false;
    }
    return true;
  }
  if (expected is num && actual is num) return expected == actual;
  return expected == actual;
}
