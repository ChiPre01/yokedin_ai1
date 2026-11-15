import 'package:http/http.dart' as http;

/// Browser implementation of the Worker HTTP client.
///
/// `dart:io` exists on the web only as a stub whose operations throw
/// (`Unsupported operation: Platform._version`), so the browser uses
/// package:http's own browser client instead.
http.Client createPlatformWorkerHttpClient() => http.Client();
