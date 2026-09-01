import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_control_plane/debug_control_plane.dart';

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('debug_auth_store_test');
  });

  tearDown(() async {
    if (tmpDir.existsSync()) {
      await tmpDir.delete(recursive: true);
    }
  });

  TokenRecord record({
    required String tokenHash,
    String tokenId = 'tok-1',
    DateTime? createdAt,
    DateTime? expiresAt,
    DateTime? revokedAt,
    String? clientLabel,
  }) {
    final now = DateTime.now().toUtc();
    return TokenRecord(
      tokenId: tokenId,
      tokenHash: tokenHash,
      createdAt: createdAt ?? now,
      expiresAt: expiresAt ?? now.add(const Duration(days: 7)),
      revokedAt: revokedAt,
      clientLabel: clientLabel,
    );
  }

  test('U1: putToken then tokenByHash roundtrips fields (in-memory)', () {
    final store = InMemoryDebugAuthStore();
    final rec = record(tokenHash: 'a' * 64, clientLabel: 'host');
    store.putToken(rec);
    final loaded = store.tokenByHash('a' * 64);
    expect(loaded, isNotNull);
    expect(loaded!.tokenId, rec.tokenId);
    expect(loaded.tokenHash, rec.tokenHash);
    expect(loaded.createdAt, rec.createdAt);
    expect(loaded.expiresAt, rec.expiresAt);
    expect(loaded.clientLabel, 'host');
    expect(store.tokenByHash('b' * 64), isNull);
  });

  test('U2: sha256 matches NIST and python vectors', () {
    expect(
      debugAuthTokenHash(''),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      debugAuthTokenHash('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    // python3 -c hashlib.sha256('你好'.encode()).hexdigest()
    expect(
      debugAuthTokenHash('你好'),
      '670d9743542cae3ea7ebe36af56bd53648b0a1126162e78d81a32934a711302e',
    );
  });

  test('U3: file roundtrip across instances', () {
    final storeA = FileBackedDebugAuthStore(directory: tmpDir.path);
    storeA.putToken(record(tokenHash: 'c' * 64, tokenId: 'tok-a'));
    final storeB = FileBackedDebugAuthStore(directory: tmpDir.path);
    final loaded = storeB.tokenByHash('c' * 64);
    expect(loaded, isNotNull);
    expect(loaded!.tokenId, 'tok-a');
  });

  test('U4: corrupt or unsupported files fall back to empty without throwing',
      () {
    final variants = <String, String>{
      'truncated': '{"version":1,"tokens":[{"tokenId":"tok"',
      'invalid-json': 'not json at all {{{',
      'version-2': '{"version":2,"tokens":[]}',
    };
    for (final entry in variants.entries) {
      final dir = Directory('${tmpDir.path}/${entry.key}')..createSync();
      File('${dir.path}/debug_auth_tokens.json').writeAsStringSync(entry.value);
      final store = FileBackedDebugAuthStore(directory: dir.path);
      expect(store.tokenByHash('d' * 64), isNull, reason: entry.key);
    }
  });

  test('U5: expired records are dropped on load without rewriting the file',
      () {
    final now = DateTime.now().toUtc();
    final expired = TokenRecord(
      tokenId: 'tok-expired',
      tokenHash: 'e' * 64,
      createdAt: now.subtract(const Duration(days: 8)),
      expiresAt: now.subtract(const Duration(days: 1)),
    );
    File('${tmpDir.path}/debug_auth_tokens.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'tokens': [expired.toJson()],
      }),
    );
    final store = FileBackedDebugAuthStore(directory: tmpDir.path);
    expect(store.tokenByHash('e' * 64), isNull);
    // Red line: load must not rewrite the file; expired row still on disk.
    final raw = File('${tmpDir.path}/debug_auth_tokens.json').readAsStringSync();
    expect(raw.contains('tok-expired'), isTrue);
  });

  test('U6: markRevoked persists revokedAt across instances', () {
    final storeA = FileBackedDebugAuthStore(directory: tmpDir.path);
    storeA.putToken(record(tokenHash: 'f' * 64, tokenId: 'tok-r'));
    final revokedAt = DateTime.now().toUtc();
    storeA.markRevoked('tok-r', revokedAt);
    final storeB = FileBackedDebugAuthStore(directory: tmpDir.path);
    final loaded = storeB.tokenByHash('f' * 64);
    expect(loaded, isNotNull);
    expect(loaded!.revokedAt, revokedAt);
  });

  test('U7: removeExpired removes expired rows and keeps valid ones', () {
    final store = InMemoryDebugAuthStore();
    final now = DateTime.now().toUtc();
    store.putToken(record(
      tokenHash: '1' * 64,
      tokenId: 'tok-expired',
      expiresAt: now.subtract(const Duration(hours: 1)),
    ));
    store.putToken(record(
      tokenHash: '2' * 64,
      tokenId: 'tok-valid',
      expiresAt: now.add(const Duration(hours: 1)),
    ));
    store.removeExpired(now);
    expect(store.tokenByHash('1' * 64), isNull);
    expect(store.tokenByHash('2' * 64), isNotNull);
  });

  test('U8: atomic writes leave no .tmp files and a decodable target', () {
    final store = FileBackedDebugAuthStore(directory: tmpDir.path);
    for (var i = 0; i < 3; i++) {
      store.putToken(record(
        tokenHash: String.fromCharCode('0'.codeUnitAt(0) + i) * 64,
        tokenId: 'tok-$i',
      ));
    }
    final files = tmpDir.listSync().whereType<File>().map((f) => f.path).toList();
    expect(files.where((p) => p.endsWith('.tmp')), isEmpty);
    final decoded =
        jsonDecode(File('${tmpDir.path}/debug_auth_tokens.json').readAsStringSync());
    expect(decoded, isA<Map<String, Object?>>());
  });

  test('U9: plaintext token never reaches disk', () {
    const secret = 'tok_secret_1';
    final store = FileBackedDebugAuthStore(directory: tmpDir.path);
    store.putToken(record(tokenHash: debugAuthTokenHash(secret)));
    final raw =
        utf8.decode(File('${tmpDir.path}/debug_auth_tokens.json').readAsBytesSync());
    expect(raw.contains(secret), isFalse);
    expect(raw.contains(debugAuthTokenHash(secret)), isTrue);
  });

  test('U10: smoke on a plain system temp directory', () {
    final dir = Directory('${tmpDir.path}/nested/plain');
    final store = FileBackedDebugAuthStore(directory: dir.path);
    store.putToken(record(tokenHash: '9' * 64));
    expect(store.tokenByHash('9' * 64), isNotNull);
  });
}
