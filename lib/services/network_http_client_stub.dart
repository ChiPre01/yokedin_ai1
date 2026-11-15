import 'package:http/http.dart' as http;

/// Fallback implementation for targets that are neither io nor web.
http.Client createPlatformWorkerHttpClient() => http.Client();
