import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// An HTTP client that does not depend on the device picking a reachable
/// address family.
///
/// Cloudflare - and therefore this project's Worker - publishes IPv6 (AAAA)
/// records next to its A records. `dart:io` can end up on the IPv6 address
/// first, and on networks that advertise IPv6 without a working route (home
/// routers, hotspots, some carriers) that connect fails with
/// `SocketException: Network is unreachable (errno = 101)`. Every Worker
/// request then fails even though the same host answers fine over IPv4.
///
/// [createWorkerHttpClient] connects to IPv4 addresses first and only then
/// tries IPv6, so media uploads and AI calls survive either kind of network.
http.Client createWorkerHttpClient() {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..connectionFactory = _ipv4FirstConnect;

  return IOClient(client);
}

/// Shared client for callers that do not inject one.
final http.Client workerHttpClient = createWorkerHttpClient();

const Duration _connectTimeout = Duration(seconds: 15);
const Duration _handshakeTimeout = Duration(seconds: 20);

/// `HttpClient.connectionFactory` hands back a socket it will not secure for
/// us, so HTTPS is wrapped here with the real host name for SNI and
/// certificate validation.
Future<ConnectionTask<Socket>> _ipv4FirstConnect(
  Uri uri,
  String? proxyHost,
  int? proxyPort,
) async {
  // Never bypass an explicitly configured proxy.
  if (proxyHost != null && proxyPort != null) {
    return Socket.startConnect(proxyHost, proxyPort);
  }

  final addresses = await InternetAddress.lookup(uri.host);

  if (addresses.isEmpty) {
    throw const SocketException('Failed host lookup');
  }

  final ordered = <InternetAddress>[
    ...addresses.where((address) => address.type == InternetAddressType.IPv4),
    ...addresses.where((address) => address.type != InternetAddressType.IPv4),
  ];

  Object? lastError;

  for (final address in ordered) {
    Socket? raw;

    try {
      final task = await Socket.startConnect(address, uri.port);
      raw = await task.socket.timeout(_connectTimeout);
    } catch (error) {
      // This address is unusable; the next one may be reachable.
      lastError = error;
      continue;
    }

    if (uri.scheme != 'https') {
      return ConnectionTask.fromSocket<Socket>(
        Future<Socket>.value(raw),
        raw.destroy,
      );
    }

    // A TLS failure is a real answer from the server, so it is propagated
    // instead of being retried against the other address family.
    final secure = await SecureSocket.secure(
      raw,
      host: uri.host,
    ).timeout(_handshakeTimeout);

    return ConnectionTask.fromSocket<Socket>(
      Future<Socket>.value(secure),
      secure.destroy,
    );
  }

  throw lastError ?? const SocketException('Could not connect');
}
