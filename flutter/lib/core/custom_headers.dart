// Extra HTTP headers and client certificates for a Jellyfin server behind a
// reverse proxy (Cloudflare Access service tokens, Authelia, mTLS). Pure.
// Ported from desktop/src/core/custom-headers.ts. A header is a (name, value)
// record; applying them to requests is the caller's job.

/// One extra header.
typedef CustomHeader = ({String name, String value});

/// More than this is a typo or paste accident.
const maxCustomHeaders = 16;
const maxHeaderValueLength = 4096;

/// Names a user may not set (lowercase): they would break request framing or replace Cascade's own sign-in.
const blockedHeaderNames = {'authorization', 'x-emby-authorization', 'host', 'content-length', 'transfer-encoding'};

// RFC 9110 token characters.
final _token = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

/// Why [name] cannot be a header name, or null when it can.
String? headerNameProblem(Object? name) {
  if (name is! String || name.isEmpty) return 'A header needs a name.';
  if (!_token.hasMatch(name)) return '"${name.length > 40 ? name.substring(0, 40) : name}" is not a valid header name.';
  if (blockedHeaderNames.contains(name.toLowerCase())) return '$name cannot be overridden.';
  return null;
}

final _controlChars = RegExp(r'[\u0000-\u0008\u000a-\u001f\u007f]');

/// Why [value] cannot be a header value, or null when it can.
String? headerValueProblem(Object? value) {
  if (value is! String || value.isEmpty) return 'A header needs a value.';
  if (value.length > maxHeaderValueLength) return 'That header value is too long.';
  // A line break would let a value smuggle in a second header.
  if (_controlChars.hasMatch(value)) return 'A header value cannot contain control characters.';
  return null;
}

/// Parses `Name: Value` lines. Blank lines and lines starting with # are skipped. Returns every problem with its line number, so one pass fixes the lot.
({List<CustomHeader> headers, List<String> errors}) parseHeaderLines(String text) {
  final headers = <CustomHeader>[];
  final errors = <String>[];
  final seen = <String>{};
  final lines = text.split(RegExp(r'\r?\n'));
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final at = line.indexOf(':');
    if (at < 0) {
      errors.add('Line ${i + 1}: use Name: Value.');
      continue;
    }
    final name = line.substring(0, at).trim();
    final value = line.substring(at + 1).trim();
    final problem = headerNameProblem(name) ?? headerValueProblem(value);
    if (problem != null) {
      errors.add('Line ${i + 1}: $problem');
      continue;
    }
    if (seen.contains(name.toLowerCase())) {
      errors.add('Line ${i + 1}: $name is listed twice.');
      continue;
    }
    seen.add(name.toLowerCase());
    headers.add((name: name, value: value));
  }
  if (headers.length > maxCustomHeaders) {
    errors.add('At most $maxCustomHeaders headers.');
    headers.removeRange(maxCustomHeaders, headers.length);
  }
  return (headers: headers, errors: errors);
}

/// The inverse of [parseHeaderLines], for filling the field.
String formatHeaderLines(List<CustomHeader> headers) => headers.map((h) => '${h.name}: ${h.value}').join('\n');

/// Headers from the store, which are untrusted: anything invalid, duplicated or past the cap is dropped, never repaired. Each entry is a Map with `name` and `value`.
List<CustomHeader> sanitizeCustomHeaders(Object? raw) {
  if (raw is! List) return [];
  final out = <CustomHeader>[];
  final seen = <String>{};
  for (final h in raw) {
    if (h is! Map) continue;
    final name = h['name'], value = h['value'];
    if (headerNameProblem(name) != null || headerValueProblem(value) != null) continue;
    if (!seen.add((name as String).toLowerCase())) continue;
    out.add((name: name, value: value as String));
    if (out.length >= maxCustomHeaders) break;
  }
  return out;
}

/// scheme://host:port with the default port left off, a WebSocket treated as the HTTP it upgrades from. Null for anything that is not an http(s) or ws(s) URL.
String? requestOrigin(Object? url) {
  if (url is! String) return null;
  final u = Uri.tryParse(url);
  if (u == null || u.host.isEmpty) return null;
  final scheme = u.scheme == 'ws' ? 'http' : u.scheme == 'wss' ? 'https' : u.scheme;
  if (scheme != 'http' && scheme != 'https') return null;
  final port = u.hasPort && !((scheme == 'http' && u.port == 80) || (scheme == 'https' && u.port == 443)) ? ':${u.port}' : '';
  final host = u.host.contains(':') ? '[${u.host}]' : u.host;
  return '$scheme://$host$port';
}

/// The headers to add to a request to [requestUrl]: all of them for the Jellyfin server's own origin, none for any other host.
List<CustomHeader> headersForRequest(String requestUrl, String? serverUrl, List<CustomHeader> headers) {
  if (headers.isEmpty || serverUrl == null || serverUrl.isEmpty) return [];
  final target = requestOrigin(requestUrl), server = requestOrigin(serverUrl);
  return target != null && server != null && target == server ? [...headers] : [];
}

/// The headers the sign-in screen's Quick Connect check may send: only to the server they were saved for, not to a half-typed host.
List<CustomHeader> probeHeaders(String typedUrl, String? savedServerUrl, List<CustomHeader> headers) {
  final typed = requestOrigin(typedUrl);
  return typed != null && typed == requestOrigin(savedServerUrl) ? [...headers] : [];
}

/// [existing] with [extra] set on it. A header already present under any capitalization is replaced, not duplicated. Returns a new map.
Map<String, Object> withCustomHeaders(Map<String, Object> existing, List<CustomHeader> extra) {
  final out = {...existing};
  for (final h in extra) {
    out.removeWhere((k, _) => k.toLowerCase() == h.name.toLowerCase());
    out[h.name] = h.value;
  }
  return out;
}

/// The slice of a certificate this reads. [validExpiry] is epoch seconds, if known.
typedef ClientCertificate = ({String fingerprint, String subjectName, String issuerName, int? validExpiry});

/// Which certificate to answer with: kind 'use' ([index]), 'ask' ([candidates]) or 'none'.
typedef CertificateChoice = ({String kind, int? index, List<int> candidates});

/// Which certificate to answer a server's request with. Indexes refer to [certs] as given. An expired one is never offered; a remembered choice wins while it is in the list; one candidate needs no question, several need one.
CertificateChoice chooseClientCertificate(List<ClientCertificate> certs, String? savedFingerprint, int nowSec) {
  final live = [
    for (var i = 0; i < certs.length; i++)
      if (certs[i].validExpiry == null || certs[i].validExpiry! >= nowSec) i,
  ];
  if (live.isEmpty) return (kind: 'none', index: null, candidates: const []);
  if (savedFingerprint != null && savedFingerprint.isNotEmpty) {
    for (final i in live) {
      if (certs[i].fingerprint == savedFingerprint) return (kind: 'use', index: i, candidates: const []);
    }
  }
  if (live.length == 1) return (kind: 'use', index: live[0], candidates: const []);
  return (kind: 'ask', index: null, candidates: live);
}
