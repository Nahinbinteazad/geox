// lib/api.dart
//
// Talks to the GeoX FastAPI server. Every call has a timeout and turns every
// failure into an ApiException with a sentence a person can read, so a dead
// server shows a clear message instead of a crash.
//
// The server address comes from AppConfig.apiUrl. Set it when running:
//   flutter run -d chrome --dart-define=GEOX_API_URL=http://localhost:8000
// (On the Android emulator use http://10.0.2.2:8000, because "localhost" there
// means the phone itself.)
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'config.dart';

class ApiException implements Exception {
  final String message;
  const ApiException(this.message);
  @override
  String toString() => message;
}

/// A point the person typed in on "Custom coordinates".
class OpenTargetQuery {
  final double lat, lon;
  final String terrain; // flat_plain | crater_floor | rough | canyon | crater_wall
  final bool shadowed; // Moon only: permanently shadowed polar floor
  const OpenTargetQuery({
    required this.lat,
    required this.lon,
    this.terrain = 'crater_floor',
    this.shadowed = false,
  });
}

class OpenTargetResult {
  final List<Map<String, dynamic>> ranked;
  final List<String> caveats;
  final String earthSource;
  const OpenTargetResult(this.ranked, this.caveats, this.earthSource);
}


/// Reads "24.5°S 69.2°W", "24.5 S, 69.2 W" or "-24.5, -69.2" into (lat, lon).
/// Returns null when the text is not two valid coordinates.
(double, double)? parseCoordinates(String text) {
  final t = text.toUpperCase().replaceAll('°', ' ').replaceAll(',', ' ').trim();
  final m = RegExp(r'^([+-]?\d+(?:\.\d+)?)\s*([NS])?\s+([+-]?\d+(?:\.\d+)?)\s*([EW])?$')
      .firstMatch(t);
  if (m == null) return null;
  var lat = double.parse(m.group(1)!);
  var lon = double.parse(m.group(3)!);
  if (m.group(2) == 'S') lat = -lat.abs();
  if (m.group(2) == 'N') lat = lat.abs();
  if (m.group(4) == 'W') lon = -lon.abs();
  if (m.group(4) == 'E') lon = lon.abs();
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  return (lat, lon);
}

class GeoXApi {
  static bool get configured => AppConfig.apiUrl.isNotEmpty;

  static Uri _u(String path) =>
      Uri.parse('${AppConfig.apiUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  /// Ranks the Earth sites against a coordinate on Mars or the Moon.
  static Future<OpenTargetResult> openTarget({
    required String planet, // 'mars' or 'moon'
    required OpenTargetQuery query,
    int topK = 25,
  }) =>
      _rank('/score/open-target', {
        'planet': planet,
        'lat': query.lat,
        'lon': query.lon,
        'terrain': query.terrain,
        'shadowed': query.shadowed,
        'top_k': topK,
      });

  /// Ranks the Earth sites against one of the server's stored targets
  /// (for example mars_jezero or moon_peary).
  static Future<OpenTargetResult> scoreTarget(String targetId, {int topK = 25}) =>
      _rank('/score/target/$targetId?top_k=$topK', null);

  static Future<OpenTargetResult> _rank(
      String path, Map<String, dynamic>? payload) async {
    if (!configured) {
      throw const ApiException(
          'The GeoX server address is not set in this build. Run the app with '
          '--dart-define=GEOX_API_URL=http://localhost:8000');
    }
    http.Response res;
    try {
      res = await http
          .post(_u(path),
              headers: {'Content-Type': 'application/json'},
              body: payload == null ? null : jsonEncode(payload))
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      throw const ApiException(
          'Could not reach the GeoX server. Check that it is running.');
    }

    Map<String, dynamic> body;
    try {
      final d = jsonDecode(res.body);
      if (d is! Map<String, dynamic>) throw const FormatException('not an object');
      body = d;
    } catch (_) {
      throw ApiException(
          'The server sent a reply the app could not read (HTTP ${res.statusCode}).');
    }

    if (res.statusCode != 200) {
      final d = body['detail'];
      var msg = 'The server refused the request (HTTP ${res.statusCode}).';
      if (d is String) {
        msg = d;
      } else if (d is List && d.isNotEmpty && d.first is Map) {
        msg = ((d.first as Map)['msg'] ?? msg).toString();
      }
      throw ApiException(msg);
    }

    final ranked = body['ranked'];
    if (ranked is! List || ranked.isEmpty) {
      throw const ApiException('The server returned no matching sites.');
    }
    return OpenTargetResult(
      ranked.whereType<Map<String, dynamic>>().toList(),
      [for (final c in (body['caveats'] as List? ?? const [])) c.toString()],
      (body['earth_source'] ?? '').toString(),
    );
  }

  static Future<(int, Map<String, dynamic>)> _call(
      Future<http.Response> Function() f) async {
    if (!configured) {
      throw const ApiException(
          'The GeoX server address is not set in this build. Run the app with '
          '--dart-define=GEOX_API_URL=http://localhost:8000');
    }
    http.Response res;
    try {
      res = await f().timeout(const Duration(seconds: 12));
    } catch (_) {
      throw const ApiException(
          'Could not reach the GeoX server. Check that it is running.');
    }
    var body = <String, dynamic>{};
    try {
      final d = jsonDecode(res.body);
      if (d is Map<String, dynamic>) body = d;
    } catch (_) {}
    return (res.statusCode, body);
  }

  /// Saves a list of site ids on the server and returns the short code to share.
  static Future<String> createShortlist(
      {required List<String> ids, String? targetId}) async {
    final (status, b) = await _call(() => http.post(_u('/shortlists'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'site_ids': ids, 'target_id': ?targetId})));
    final code = b['code']?.toString();
    if (status != 201 || code == null) {
      final d = b['detail'];
      throw ApiException(d is String
          ? d
          : 'The server could not save the shortlist (HTTP $status).');
    }
    return code;
  }

  /// Opens a shared shortlist by its code.
  static Future<SharedList> readShortlist(String code) async {
    final (status, b) = await _call(
        () => http.get(_u('/shortlists/${Uri.encodeComponent(code.trim())}')));
    if (status == 404) throw const ApiException('No shortlist with that code.');
    if (status != 200) {
      throw ApiException('The server could not open that shortlist (HTTP $status).');
    }
    final sites = <SharedSite>[];
    for (final s in (b['sites'] as List? ?? const []).whereType<Map>()) {
      sites.add(SharedSite(
          s['id'].toString(),
          s['name']?.toString(),
          (s['lat'] as num?)?.toDouble(),
          (s['lon'] as num?)?.toDouble(),
          s['missing'] == true));
    }
    return SharedList((b['code'] ?? code).toString(), b['target_id']?.toString(), sites);
  }

  /// Sends a candidate site to the server. Needs a signed-in user's token.
  /// Returns the server's note on success.
  static Future<String> suggestSite({
    required String token,
    required String name,
    required double lat,
    required double lon,
    required String why,
    String? category,
  }) async {
    if (!configured) {
      throw const ApiException(
          'The GeoX server address is not set in this build. Run the app with '
          '--dart-define=GEOX_API_URL=http://localhost:8000');
    }
    http.Response res;
    try {
      res = await http
          .post(_u('/sites/suggest'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({
                'name': name,
                'latitude': lat,
                'longitude': lon,
                'why': why,
                'category': ?category,
              }))
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      throw const ApiException(
          'Could not reach the GeoX server. Check that it is running.');
    }
    Map<String, dynamic> body = {};
    try {
      final d = jsonDecode(res.body);
      if (d is Map<String, dynamic>) body = d;
    } catch (_) {}
    if (res.statusCode == 401) {
      throw const ApiException('Your sign-in has expired. Please log in again.');
    }
    if (res.statusCode != 201 && res.statusCode != 200) {
      final d = body['detail'];
      var msg = 'The server refused the suggestion (HTTP ${res.statusCode}).';
      if (d is String) {
        msg = d;
      } else if (d is List && d.isNotEmpty && d.first is Map) {
        final f = d.first as Map;
        final loc = (f['loc'] is List && (f['loc'] as List).isNotEmpty)
            ? '${(f['loc'] as List).last}: '
            : '';
        msg = '$loc${f['msg'] ?? msg}';
      }
      throw ApiException(msg);
    }
    return (body['note'] ?? 'Stored as pending review.').toString();
  }
}

/// The validated ranking that ships inside the app (assets/geox_data.json).
/// It works with no server and no internet, and carries the satellite-image
/// ("visual") score that the live server does not compute.
class BundledData {
  static Map<String, dynamic>? _cache;

  static Future<Map<String, dynamic>> _data() async {
    final c = _cache;
    if (c != null) return c;
    try {
      final d = jsonDecode(await rootBundle.loadString('assets/geox_data.json'));
      if (d is! Map<String, dynamic>) throw const FormatException('not an object');
      return _cache = d;
    } catch (_) {
      throw const ApiException('The data file bundled with the app could not be read.');
    }
  }

  static Future<OpenTargetResult> rankingFor(String targetId) async {
    final d = await _data();
    final results = d['results'];
    final res = results is Map ? results[targetId] : null;
    if (res is! Map || res['ranked'] is! List) {
      throw ApiException('No bundled ranking for $targetId.');
    }
    final byId = {
      for (final s in (d['sites'] as List? ?? const []).whereType<Map>())
        s['id'].toString(): s
    };
    final ranked = <Map<String, dynamic>>[];
    for (final r in (res['ranked'] as List).whereType<Map>()) {
      final s = byId[r['site_id'].toString()];
      if (s == null) continue;
      ranked.add({
        ...Map<String, dynamic>.from(r),
        'name': s['raw_name'] ?? s['name'],
        'region': s['region'],
        'lat': s['lat'],
        'lon': s['lon'],
        'category': s['category'],
        'known_analogue': s['known_analogue'],
      });
    }
    if (ranked.isEmpty) {
      throw const ApiException('The bundled ranking for this target is empty.');
    }

    String one(num? v) => v == null ? '?' : v.toStringAsFixed(1);
    final notes = <String>[];
    final scoring = res['scoring'] is Map ? res['scoring'] as Map : const {};
    if (scoring['visual_used'] == true) {
      final w = d['pipeline'] is Map && (d['pipeline'] as Map)['fusion_weights'] is Map
          ? (d['pipeline'] as Map)['fusion_weights'] as Map
          : const {};
      final we = ((w['environmental'] as num?) ?? 0.75) * 100;
      final wv = ((w['visual'] as num?) ?? 0.25) * 100;
      notes.add(
          'Score = ${we.round()}% environment + ${wv.round()}% visual similarity of satellite tiles.');
      final low = ranked.where((r) => r['visual_reliable'] == false).length;
      if (low > 0) {
        notes.add(
            '$low of the ${ranked.length} sites shown have a low-confidence visual score, marked on their pages.');
      }
    } else {
      notes.add(
          'No satellite comparison for this target (${scoring['visual_off_reason'] ?? 'no usable tile'}), so it is scored on environment alone.');
    }
    final val = res['validation'] is Map ? res['validation'] as Map : const {};
    if (val['benchmark_applies'] == true) {
      notes.add(
          'Check against known analogues: they average ${one(val['known_mean_score'] as num?)} against ${one(val['control_mean_score'] as num?)} for control sites (higher is better).');
    } else if (val['benchmark_scope_note'] != null) {
      notes.add(val['benchmark_scope_note'].toString());
    }
    final pl = d['pipeline'] is Map ? d['pipeline'] as Map : const {};
    final pn = pl['notes'];
    if (pn is List) {
      for (final n in pn.take(2)) {
        notes.add(n.toString());
      }
    }
    final vs = d['validation_summary'];
    if (vs is Map && vs['honest_note'] != null) notes.add(vs['honest_note'].toString());
    if (pl['disclaimer'] != null) notes.add(pl['disclaimer'].toString());
    return OpenTargetResult(ranked, notes, 'bundled geox_data.json');
  }
}

/// One target's year-by-year similarity for its best-matching site.
class TrendInfo {
  final String siteName;
  final List<int> years;
  final List<double> similarity;
  final double slopePerYear, pValue;
  final bool significant;

  /// Across all stored targets, so the page can say how rare a real trend is.
  final int significantCount, total;
  final bool significantAllFalling;
  const TrendInfo(this.siteName, this.years, this.similarity, this.slopePerYear,
      this.pValue, this.significant, this.significantCount, this.total,
      this.significantAllFalling);
}

/// A place from the bundled "how alien is your location" table.
class ReverseEntry {
  final String label;
  final double lat, lon, percentile;
  final String verdict, note;
  final String marsName, moonName;
  final double marsScore, marsPct, moonScore, moonPct;
  final List<String> top3;
  const ReverseEntry(
      this.label,
      this.lat,
      this.lon,
      this.percentile,
      this.verdict,
      this.note,
      this.marsName,
      this.marsScore,
      this.marsPct,
      this.moonName,
      this.moonScore,
      this.moonPct,
      this.top3);
}

extension BundledAnalysis on BundledData {
  static Future<TrendInfo> trendFor(String targetId) async {
    final d = await BundledData._data();
    final results = d['results'];
    final res = results is Map ? results[targetId] : null;
    final t = res is Map ? res['trend'] : null;
    if (t is! Map || t['years'] is! List || t['similarity'] is! List) {
      throw ApiException('No stored trend for $targetId.');
    }
    var sig = 0, total = 0, falling = true;
    (results as Map).forEach((_, r) {
      final tr = r is Map ? r['trend'] : null;
      if (tr is! Map) return;
      total++;
      if (tr['significant'] == true) {
        sig++;
        if (((tr['sen_slope_per_year'] as num?) ?? 0) >= 0) falling = false;
      }
    });
    return TrendInfo(
        (t['site_name'] ?? 'the best-matching site').toString(),
        [for (final y in t['years'] as List) (y as num).toInt()],
        [for (final v in t['similarity'] as List) (v as num).toDouble()],
        ((t['sen_slope_per_year'] as num?) ?? 0).toDouble(),
        ((t['mann_kendall_p'] as num?) ?? 1).toDouble(),
        t['significant'] == true,
        sig,
        total,
        sig > 0 && falling);
  }

  static Future<List<ReverseEntry>> reverseEntries() async {
    final d = await BundledData._data();
    final names = {
      for (final t in (d['targets'] as List? ?? const []).whereType<Map>())
        t['id'].toString(): t['name'].toString()
    };
    double n(Object? v) => v is num ? v.toDouble() : 0;
    final out = <ReverseEntry>[];
    for (final r in (d['reverse'] as List? ?? const []).whereType<Map>()) {
      final m = r['best_mars'] is Map ? r['best_mars'] as Map : const {};
      final o = r['best_moon'] is Map ? r['best_moon'] as Map : const {};
      out.add(ReverseEntry(
          r['label'].toString(),
          n(r['lat']),
          n(r['lon']),
          n(r['earth_percentile']),
          (r['verdict'] ?? '').toString(),
          (r['note'] ?? '').toString(),
          names[m['target_id']] ?? '',
          n(m['environmental_score']),
          n(m['percentile_vs_earth_sites']),
          names[o['target_id']] ?? '',
          n(o['environmental_score']),
          n(o['percentile_vs_earth_sites']),
          [for (final t in (r['top_3'] as List? ?? const [])) names[t] ?? t.toString()]));
    }
    if (out.isEmpty) throw const ApiException('No bundled locations found.');
    return out;
  }
}

/// What the bundled data says about one standard target.
class TargetInfo {
  final String description;
  final Map<String, double> features;
  final Map<String, String> confidence;
  final String tileSource;
  final bool visualScoring;
  const TargetInfo(this.description, this.features, this.confidence,
      this.tileSource, this.visualScoring);
}

extension BundledTargets on BundledData {
  static Future<TargetInfo> targetInfo(String targetId) async {
    final d = await BundledData._data();
    final t = (d['targets'] as List? ?? const [])
        .whereType<Map>()
        .where((x) => x['id'] == targetId)
        .firstOrNull;
    if (t == null) throw ApiException('No stored target $targetId.');
    final f = <String, double>{};
    if (t['features'] is Map) {
      (t['features'] as Map).forEach((k, v) {
        if (v is num) f['$k'] = v.toDouble();
      });
    }
    final c = <String, String>{};
    if (t['value_confidence'] is Map) {
      (t['value_confidence'] as Map).forEach((k, v) => c['$k'] = '$v');
    }
    final tile = t['tile'] is Map ? t['tile'] as Map : const {};
    return TargetInfo((t['description'] ?? '').toString(), f, c,
        (tile['source'] ?? '').toString(), t['visual_scoring'] == true);
  }

  /// The measured values stored for one Earth site (empty when it is not found).
  static Future<Map<String, double>> siteFeatures(String siteId) async {
    final d = await BundledData._data();
    final site = (d['sites'] as List? ?? const [])
        .whereType<Map>()
        .where((x) => x['id'] == siteId)
        .firstOrNull;
    final out = <String, double>{};
    if (site != null && site['features'] is Map) {
      (site['features'] as Map).forEach((k, v) {
        if (v is num) out['$k'] = v.toDouble();
      });
    }
    return out;
  }
}

class SharedSite {
  final String id;
  final String? name;
  final double? lat, lon;
  final bool missing;
  const SharedSite(this.id, this.name, this.lat, this.lon, this.missing);
}

class SharedList {
  final String code;
  final String? targetId;
  final List<SharedSite> sites;
  const SharedList(this.code, this.targetId, this.sites);
}