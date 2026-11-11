import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'exceptions.dart';

/// Upper bound on any response body the CLI accepts. A hostile or broken
/// origin returning an unbounded stream would otherwise OOM the process
/// before it can be parsed. Shared by the authenticated API client and the
/// public delivery client so the guard can't drift between them.
const int kMaxResponseBytes = 64 * 1024 * 1024;

/// Sends [request] and reads at most [kMaxResponseBytes], aborting a body
/// that declares or streams past the ceiling instead of buffering it whole.
///
/// A [TlsException], at the handshake or mid-body, comes out as the
/// [http.ClientException] a refused connection already is: `IOClient`
/// converts only socket and HTTP errors, and every caller reports a
/// [http.ClientException] as "Could not reach".
Future<http.Response> sendCapped(
  http.Client client,
  http.BaseRequest request,
) async {
  try {
    return await _sendCapped(client, request);
  } on TlsException catch (e) {
    throw http.ClientException('$e'.replaceAll(RegExp(r'\s+'), ' '), request.url);
  }
}

Future<http.Response> _sendCapped(
  http.Client client,
  http.BaseRequest request,
) async {
  final streamed = await client.send(request);
  final declared = streamed.contentLength;
  if (declared != null && declared > kMaxResponseBytes) {
    // Rejecting before reading would leave the stream unlistened and leak the
    // socket; cancel it explicitly.
    await streamed.stream.listen(null).cancel();
    throw CliException(
      'Response from ${request.url.host} too large ($declared bytes).',
    );
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in streamed.stream) {
    builder.add(chunk);
    if (builder.length > kMaxResponseBytes) {
      throw CliException(
        'Response from ${request.url.host} exceeded $kMaxResponseBytes bytes.',
      );
    }
  }
  return http.Response.bytes(
    builder.takeBytes(),
    streamed.statusCode,
    headers: streamed.headers,
    request: request,
    reasonPhrase: streamed.reasonPhrase,
  );
}
