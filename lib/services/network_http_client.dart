import 'package:http/http.dart' as http;

import 'network_http_client_stub.dart'
    if (dart.library.io) 'network_http_client_io.dart'
    if (dart.library.js_interop) 'network_http_client_web.dart';

/// The HTTP client every Worker request uses.
///
/// On mobile and desktop the platform implementation connects to IPv4 first,
/// because Cloudflare publishes AAAA records next to its A records and some
/// networks advertise IPv6 without a working route.
///
/// On the web there is no `dart:io` socket layer at all (`HttpClient` throws
/// `Unsupported operation: Platform._version`), so the browser implementation
/// returns the normal fetch/XHR client. Sharing the io client with the browser
/// build was what made uploads and image downloads fail on Chrome.
http.Client createWorkerHttpClient() => createPlatformWorkerHttpClient();

/// Shared client for callers that do not inject one.
final http.Client workerHttpClient = createWorkerHttpClient();
