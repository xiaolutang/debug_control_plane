/// HTTP wire codec helpers (JSON read / write, server endpoint discovery).
///
/// Byte-level compatible port of the legacy internal debug runtime
/// top-level functions (lines 532–619). Promoted from private
/// `_readObject` / `_requiredObject` / ... to public package utilities so
/// [HttpSseTransport] and downstream transports can reuse them without
/// re-implementing the wire contract.
///
/// Errors raised here use the framework's public [RouteFailure] (was
/// `_RouteFailure`) so the control plane's central error funnel can map them
/// to the same `{ok:false, code, message}` body the legacy runtime emitted.
///
/// Zero business dependencies: this file only touches `dart:convert` +
/// `dart:io` + [route_failure.dart].
library;

import 'dart:convert';
import 'dart:io';

import 'route_failure.dart';

/// Read and JSON-decode the body of [request] as a `Map<String,Object?>`.
///
/// Throws [RouteFailure] (400 `invalid_request`) on any decode error or when
/// the top-level JSON value is not an object. Byte-level compatible with the
/// legacy `_readObject`.
Future<Map<String, Object?>> readObject(HttpRequest request) async {
  try {
    final decoded = jsonDecode(await utf8.decoder.bind(request).join());
    return requiredObject(decoded);
  } catch (error) {
    if (error is RouteFailure) rethrow;
    throw const RouteFailure(
      HttpStatus.badRequest,
      'invalid_request',
      'Request body must be valid JSON object.',
    );
  }
}

/// Coerce [value] into a `Map<String,Object?>`, throwing [RouteFailure]
/// (400 `invalid_request`) if it is not an object.
Map<String, Object?> requiredObject(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return Map<String, Object?>.from(value);
  throw const RouteFailure(
    HttpStatus.badRequest,
    'invalid_request',
    'Expected object.',
  );
}

/// Require [value] to be a non-empty string, else throw [RouteFailure]
/// (400 `invalid_request`).
String requiredString(Object? value) {
  if (value is String && value.isNotEmpty) return value;
  throw const RouteFailure(
    HttpStatus.badRequest,
    'invalid_request',
    'Expected non-empty string.',
  );
}

/// Optional-string variant of [requiredString]: `null` passes through.
String? optionalString(Object? value) {
  if (value == null) return null;
  return requiredString(value);
}

/// Write [body] as a JSON response with the given [statusCode] and close the
/// response. Byte-level compatible with the legacy `_writeJson`.
Future<void> writeJson(
  HttpResponse response,
  Map<String, Object?> body, {
  int statusCode = HttpStatus.ok,
}) async {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}

/// Write a `{ok:false, code, message}` error body. Byte-level compatible
/// with the legacy `_writeError`.
Future<void> writeError(
  HttpResponse response,
  int statusCode,
  String code,
  String message,
) {
  return writeJson(
    response,
    <String, Object?>{'ok': false, 'code': code, 'message': message},
    statusCode: statusCode,
  );
}

/// Resolve the (host, port) the client used to reach this server, from the
/// `Host` header. Returns `(host: '0.0.0.0', port: 0)` when the header is
/// absent. Byte-level compatible with the legacy `_requestEndpoint`.
({String host, int port}) requestEndpoint(HttpRequest request) {
  final hostHeader = request.headers.host;
  if (hostHeader != null && hostHeader.isNotEmpty) {
    final uri = Uri.parse('http://$hostHeader');
    return (host: uri.host, port: uri.hasPort ? uri.port : 80);
  }
  return (host: '0.0.0.0', port: 0);
}

/// Enumerate non-loopback, non-link-local IPv4 addresses of this host.
///
/// Returns an empty list on any failure (never throws). Byte-level
/// compatible with the legacy `_localIPv4Addresses`.
Future<List<String>> localIPv4Addresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    final addresses = <String>{
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback && !address.isLinkLocal) address.address,
    }.toList();
    addresses.sort();
    return addresses;
  } catch (_) {
    return const <String>[];
  }
}
