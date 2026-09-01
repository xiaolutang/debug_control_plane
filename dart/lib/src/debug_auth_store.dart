/// Token persistence for the debug auth domain (R005-BF001).
///
/// Mirrors the Kotlin `PluginDebugAuth` store contract: an in-memory working
/// set keyed by token hash, plus a file-backed decorator that mirrors token
/// writes to a JSON file via tmp+rename atomic replace. The plaintext token
/// is never known to this store — only its sha256 hash (red line).
library;

import 'dart:convert';
import 'dart:io';

/// Public hash entry point for hosts wiring the auth domain.
///
/// Alias of the internal sha256 implementation; Kotlin `DebugAuth.tokenHash`
/// is public for the same reason (decision DEC-R005-002).
String debugAuthTokenHash(String token) => _sha256Hex(token);

/// A persisted debug-auth token record (hash only — never the plaintext).
class TokenRecord {
  const TokenRecord({
    required this.tokenId,
    required this.tokenHash,
    required this.createdAt,
    required this.expiresAt,
    this.revokedAt,
    this.clientLabel,
  });

  final String tokenId;
  final String tokenHash;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? revokedAt;
  final String? clientLabel;

  Map<String, Object?> toJson() => <String, Object?>{
        'tokenId': tokenId,
        'tokenHash': tokenHash,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'revokedAt': revokedAt?.toUtc().toIso8601String(),
        'clientLabel': clientLabel,
      };

  factory TokenRecord.fromJson(Map<String, Object?> json) => TokenRecord(
        tokenId: json['tokenId']! as String,
        tokenHash: json['tokenHash']! as String,
        createdAt: DateTime.parse(json['createdAt']! as String),
        expiresAt: DateTime.parse(json['expiresAt']! as String),
        revokedAt: json['revokedAt'] == null
            ? null
            : DateTime.parse(json['revokedAt']! as String),
        clientLabel: json['clientLabel'] == null
            ? null
            : json['clientLabel']! as String,
      );
}

/// Token-group storage contract for the debug auth domain.
abstract interface class DebugAuthStore {
  TokenRecord? tokenByHash(String tokenHash);

  void putToken(TokenRecord record);

  void markRevoked(String tokenId, DateTime revokedAt);

  void markAllRevoked(DateTime revokedAt);

  void removeExpired(DateTime now);
}

/// In-memory working set; the map is keyed by token hash (red line).
class InMemoryDebugAuthStore implements DebugAuthStore {
  final Map<String, TokenRecord> _tokens = {};

  /// Full token-set snapshot for persistence consumers.
  List<TokenRecord> snapshot() => _tokens.values.toList();

  @override
  TokenRecord? tokenByHash(String tokenHash) => _tokens[tokenHash];

  @override
  void putToken(TokenRecord record) {
    _tokens[record.tokenHash] = record;
  }

  static TokenRecord _withRevoked(TokenRecord record, DateTime revokedAt) =>
      TokenRecord(
        tokenId: record.tokenId,
        tokenHash: record.tokenHash,
        createdAt: record.createdAt,
        expiresAt: record.expiresAt,
        revokedAt: revokedAt,
        clientLabel: record.clientLabel,
      );

  @override
  void markRevoked(String tokenId, DateTime revokedAt) {
    final record = _tokens.values
        .where((r) => r.tokenId == tokenId)
        .firstOrNull;
    if (record == null) return;
    _tokens[record.tokenHash] = _withRevoked(record, revokedAt);
  }

  @override
  void markAllRevoked(DateTime revokedAt) {
    _tokens.updateAll((_, record) => _withRevoked(record, revokedAt));
  }

  @override
  void removeExpired(DateTime now) {
    _tokens.removeWhere((_, record) => !record.expiresAt.isAfter(now));
  }
}

/// File-backed decorator over [InMemoryDebugAuthStore].
///
/// Lazy load: the first token access (read or write) loads the JSON file.
/// Persistence is fail-soft: a corrupt/unreadable file falls back to empty,
/// an IO failure during persist leaves memory untouched. Expired records are
/// dropped on load without rewriting the file (unlike the Kotlin side).
class FileBackedDebugAuthStore implements DebugAuthStore {
  FileBackedDebugAuthStore({
    required this.directory,
    InMemoryDebugAuthStore? delegate,
  })  : _delegate = delegate ?? InMemoryDebugAuthStore(),
        _loaded = false;

  final String directory;
  final InMemoryDebugAuthStore _delegate;
  bool _loaded;

  static const String _fileName = 'debug_auth_tokens.json';
  static const String _tmpName = 'debug_auth_tokens.json.tmp';

  File get _file => File('$directory/$_fileName');
  File get _tmpFile => File('$directory/$_tmpName');

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    try {
      Directory(directory).createSync(recursive: true);
    } catch (_) {
      // Fail-soft: persist will retry directory creation implicitly via file
      // writes; unreadable directory falls back to an empty store.
    }
    try {
      if (!_file.existsSync()) return;
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map<String, Object?>) return;
      if (decoded['version'] != 1) return;
      final tokens = decoded['tokens'];
      if (tokens is! List<Object?>) return;
      final now = DateTime.now();
      for (final entry in tokens) {
        if (entry is! Map<String, Object?>) continue;
        final record = TokenRecord.fromJson(entry);
        if (!record.expiresAt.isAfter(now)) continue; // drop, no rewrite
        _delegate.putToken(record);
      }
    } catch (_) {
      // Fail-soft: corrupt file falls back to empty; no throw.
    }
  }

  @override
  TokenRecord? tokenByHash(String tokenHash) {
    _ensureLoaded();
    return _delegate.tokenByHash(tokenHash);
  }

  @override
  void putToken(TokenRecord record) {
    _ensureLoaded();
    _delegate.putToken(record);
    _persist();
  }

  @override
  void markRevoked(String tokenId, DateTime revokedAt) {
    _ensureLoaded();
    _delegate.markRevoked(tokenId, revokedAt);
    _persist();
  }

  @override
  void markAllRevoked(DateTime revokedAt) {
    _ensureLoaded();
    _delegate.markAllRevoked(revokedAt);
    _persist();
  }

  @override
  void removeExpired(DateTime now) {
    _ensureLoaded();
    _delegate.removeExpired(now);
    _persist();
  }

  void _persist() {
    try {
      final payload = jsonEncode(<String, Object?>{
        'version': 1,
        'tokens': _delegate.snapshot().map((r) => r.toJson()).toList(),
      });
      Directory(directory).createSync(recursive: true);
      _tmpFile.writeAsStringSync(payload, flush: true);
      _tmpFile.renameSync(_file.path);
    } catch (_) {
      // Fail-soft: keep in-memory state, never throw.
    }
  }
}

/// Pure-Dart sha256 (FIPS 180-4); no external dependencies (decision D2).
String _sha256Hex(String input) {
  final message = utf8.encode(input);
  // Pre-processing: append 0x80, pad with zeros, append 64-bit bit length.
  final bitLength = message.length * 8;
  final padded = List<int>.from(message)..add(0x80);
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    padded.add((bitLength >> (8 * i)) & 0xff);
  }

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  const k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

  for (var block = 0; block < padded.length; block += 64) {
    final w = List<int>.filled(64, 0);
    for (var t = 0; t < 16; t++) {
      final i = block + t * 4;
      w[t] = (padded[i] << 24) | (padded[i + 1] << 16) |
          (padded[i + 2] << 8) | padded[i + 3];
    }
    for (var t = 16; t < 64; t++) {
      final s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;

    for (var t = 0; t < 64; t++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 = (h + s1 + ch + k[t] + w[t]) & 0xffffffff;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
    h5 = (h5 + f) & 0xffffffff;
    h6 = (h6 + g) & 0xffffffff;
    h7 = (h7 + h) & 0xffffffff;
  }

  final out = StringBuffer();
  for (final word in [h0, h1, h2, h3, h4, h5, h6, h7]) {
    out.write(word.toRadixString(16).padLeft(8, '0'));
  }
  return out.toString();
}
