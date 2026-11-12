import 'dart:async' show Completer;
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'config.dart';

// Coastline outlines live in their own file (see land_data.dart).
import 'land_data.dart';
import 'ask_geox_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Auth.restore(); // sign the person back in if they were signed in before
  await Shortlist.load(); // bring back the saved shortlist
  await SavedPriorities.load(); // and the saved priorities
  runApp(const GeoXApp());
}

/// Set to false once real data from geox_data.json is wired in.
const bool kPreviewData = true;

// ───────────── Design tokens ─────────────
const bg = Color(0xFF070A10),
    card = Color(0xFF0E131C),
    line = Color(0xFF1B2333),
    accent = Color(0xFFE8743B),
    fg = Color(0xFFE6E9EF),
    muted = Color(0xFF7C8596),
    teal = Color(0xFF5B9BB0);

TextStyle mono(double s, [Color c = muted]) => TextStyle(
    fontFamily: 'monospace', fontSize: s, letterSpacing: 1.3, color: c);
TextStyle head(double s, [Color c = fg]) => TextStyle(
    fontSize: s,
    fontWeight: FontWeight.w800,
    height: 1.05,
    color: c,
    letterSpacing: -0.5);

class GeoXApp extends StatelessWidget {
  const GeoXApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'GeoX',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: bg,
          colorScheme: const ColorScheme.dark(primary: accent, surface: card),
        ),
        navigatorObservers: [NavHistory.instance],
        home: const HomeScreen(),
      );
}

// ───────────── Data ─────────────
const labels = ['TERRAIN', 'THERMAL', 'ARIDITY', 'VEG', 'BARE'];
const targets = [92, 90, 90, 98, 98];

enum Category { desert, polar, volcanic, cave, other }

String categoryLabel(Category c) => switch (c) {
      Category.desert => 'DESERT',
      Category.polar => 'POLAR',
      Category.volcanic => 'VOLCANIC',
      Category.cave => 'CAVE',
      Category.other => 'OTHER',
    };

IconData categoryIcon(Category c) => switch (c) {
      Category.desert => Icons.wb_sunny_outlined,
      Category.polar => Icons.ac_unit,
      Category.volcanic => Icons.local_fire_department_outlined,
      Category.cave => Icons.landscape_outlined,
      Category.other => Icons.public,
    };

class Site {
  /// The dataset's id for this Earth site (empty for the placeholder list).
  final String id;
  final String name, meta, tag;
  final int score;
  final List<double> radar;
  final Offset pos; // map position (fractions)
  final Category category;

  /// True when the numbers came from the GeoX server for a point the person chose.
  final bool live;

  /// Names of the radar axes. A live result leaves out axes the server did not score.
  final List<String> axes;

  /// Mission relevance 0..100 keyed rover / geology / astrobiology / eva / isru (live only).
  final Map<String, double> mission;

  /// 'preview' (placeholder list), 'server' (live scoring) or 'bundle' (validated data in the app).
  final String source;

  /// Satellite-image similarity 0..100 when the validated data has one.
  final double? visual;
  final bool visualReliable;
  const Site(this.name, this.meta, this.tag, this.score, this.radar, this.pos,
      this.category,
      {this.live = false,
      this.axes = labels,
      this.mission = const {},
      this.source = 'preview',
      this.visual,
      this.visualReliable = true,
      this.id = ''});

  /// The same site with a new position and score (used when results are re-ranked).
  Site withRank(int rank, int newScore) => Site(
      name,
      meta.replaceFirst(RegExp(r'RANK \d+'), 'RANK ${rank.toString().padLeft(2, '0')}'),
      tag,
      newScore,
      radar,
      pos,
      category,
      live: live,
      axes: axes,
      mission: mission,
      source: source,
      visual: visual,
      visualReliable: visualReliable,
      id: id);
}

/// Re-orders live results by the person's weights over the five fingerprint
/// axes. An axis a result does not have (aridity for another world) is left
/// out and the remaining weights are rescaled.
List<Site> reRankSites(List<Site> base, List<double> w) {
  const order = ['TERRAIN', 'THERMAL', 'ARIDITY', 'VEG', 'BARE'];
  double score(Site s) {
    var sum = 0.0, den = 0.0;
    for (var i = 0; i < s.axes.length; i++) {
      final k = order.indexOf(s.axes[i]);
      if (k < 0 || k >= w.length) continue;
      sum += w[k] * s.radar[i] * 100;
      den += w[k];
    }
    return den <= 0 ? s.score.toDouble() : sum / den;
  }

  final scored = [for (final s in base) (s, score(s))]
    ..sort((a, b) => b.$2.compareTo(a.$2));
  return [
    for (var i = 0; i < scored.length; i++)
      scored[i].$1.withRank(i + 1, scored[i].$2.round())
  ];
}

String fmtCoords(double lat, double lon) =>
    '${lat.abs().toStringAsFixed(1)}°${lat >= 0 ? 'N' : 'S'} '
    '${lon.abs().toStringAsFixed(1)}°${lon >= 0 ? 'E' : 'W'}';

/// Turns one entry of the server's `ranked` list into a [Site].
Site siteFromRanked(Map<String, dynamic> r) {
  double n(Object? v) => v is num ? v.toDouble() : 0.0;
  final Map fp = r['fingerprint'] is Map ? r['fingerprint'] as Map : const {};
  const names = [
    ('terrain', 'TERRAIN'),
    ('thermal', 'THERMAL'),
    ('aridity', 'ARIDITY'),
    ('vegetation', 'VEG'),
    ('bare_ground', 'BARE'),
  ];
  final axes = <String>[];
  final radar = <double>[];
  for (final a in names) {
    final v = fp[a.$1];
    if (v is num) {
      axes.add(a.$2);
      radar.add((v.toDouble() / 100).clamp(0.0, 1.0));
    }
  }
  final lat = n(r['lat']), lon = n(r['lon']);
  final rank = r['rank'] is num ? (r['rank'] as num).toInt() : 0;
  final region = (r['region'] ?? '').toString().toUpperCase();
  final cat = switch ((r['category'] ?? '').toString()) {
    'desert' => Category.desert,
    'polar' => Category.polar,
    'volcanic' => Category.volcanic,
    'cave' => Category.cave,
    _ => Category.other,
  };
  final mission = <String, double>{};
  final m = r['mission_relevance'];
  if (m is Map) {
    m.forEach((k, v) {
      if (v is num) mission['$k'] = v.toDouble();
    });
  }
  return Site(
      (r['name'] ?? r['site_id'] ?? 'Unnamed site').toString(),
      [
        'RANK ${rank.toString().padLeft(2, '0')}',
        if (region.isNotEmpty) region,
        fmtCoords(lat, lon),
      ].join(' · '),
      r['known_analogue'] == true ? 'KNOWN' : 'CANDIDATE',
      n(r['fusion_score'] ?? r['environmental_score']).round(),
      radar,
      Offset(((lon + 180) / 360).clamp(0.03, 0.97).toDouble(),
          ((90 - lat) / 180).clamp(0.05, 0.95).toDouble()),
      cat,
      live: true,
      axes: axes,
      mission: mission,
      source: r.containsKey('fusion_score') ? 'bundle' : 'server',
      visual: r['visual_score'] is num ? (r['visual_score'] as num).toDouble() : null,
      visualReliable: r['visual_reliable'] != false,
      id: (r['site_id'] ?? '').toString());
}

// Mutable (not const) so newly suggested candidate sites can be appended
// at runtime — this is where a real backend would eventually replace the
// fixed list with a live query.
final List<Site> sites = [
  Site('Atacama Desert', 'RANK 01 · CHILE · 24.5°S 69.2°W', 'KNOWN', 91,
      [.88, .84, .96, .96, .94], const Offset(.42, .55), Category.desert),
  Site('Dry Valleys', 'RANK 02 · ANTARCTICA · 77.5°S 162°E', 'KNOWN', 87,
      [.80, .82, .90, .92, .88], const Offset(.70, .30), Category.polar),
  Site('Altiplano Salt Flat', 'RANK 03 · BOLIVIA · 20.1°S 67.5°W',
      'CANDIDATE', 84, [.78, .80, .85, .90, .86], const Offset(.25, .35),
      Category.desert),
  Site('Haughton Crater', 'RANK 04 · DEVON ISLAND, CANADA · 75.4°N 89.9°W',
      'KNOWN', 88, [.86, .78, .70, .60, .80], const Offset(.60, .18),
      Category.polar),
  Site('Erta Ale', 'RANK 05 · ETHIOPIA · 13.6°N 40.7°E', 'CANDIDATE', 79,
      [.72, .90, .82, .40, .76], const Offset(.80, .62), Category.volcanic),
  Site('Undara Lava Tubes', 'RANK 06 · AUSTRALIA · 18.2°S 144.6°E',
      'CANDIDATE', 75, [.66, .60, .74, .55, .70], const Offset(.15, .70),
      Category.cave),
];

// ───────────── Glossary ─────────────
const _glossary = [
  ('NDVI', 'Normalised Difference Vegetation Index. A satellite measure of how green a surface is. Near zero means bare ground.'),
  ('Aridity index', 'How dry a place is: rainfall compared with the water the air could evaporate. Lower means drier.'),
  ('Terrain', 'How uneven the surface is at the scale a rover meets it: slope and roughness.'),
  ('Thermal', 'Land surface temperature, including how much it swings between day and night and across seasons.'),
  ('Bare ground', 'The share of the surface with little or no plant cover.'),
  ('Fidelity', 'How closely a site\'s measured conditions match the target. It ranks sites for one target and is not an absolute measurement.'),
  ('Known vs candidate', 'Known: scientists already use it as an analogue. Candidate: it matches the numbers but still needs validating.'),
  ('ISRU', 'In-situ resource utilisation: making water, oxygen or fuel from local material.'),
  ('EVA', 'Extravehicular activity: a spacewalk or a suited excursion on the surface.'),
];

class GlossaryScreen extends StatelessWidget {
  const GlossaryScreen({super.key});
  @override
  Widget build(BuildContext c) => frame(
      c,
      'GLOSSARY',
      ListView(children: [
        Text('PLAIN-WORD DEFINITIONS', style: mono(9)),
        const SizedBox(height: 8),
        Text('Glossary', style: head(30)),
        const SizedBox(height: 14),
        for (final t in _glossary)
          Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Panel(
                  stars: false,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.$1.toUpperCase(), style: mono(10, accent)),
                    const SizedBox(height: 6),
                    Text(t.$2, style: const TextStyle(color: fg, height: 1.4)),
                  ]))),
      ]),
      back: true);
}

// ───────────── Preview-data notice ─────────────
class _PreviewNote extends StatelessWidget {
  const _PreviewNote();
  @override
  Widget build(BuildContext c) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        const Icon(Icons.info_outline, size: 13, color: _warn),
        const SizedBox(width: 6),
        Expanded(
            child: Text('PREVIEW DATA · NOT YET FROM geox_data.json',
                style: mono(9, _warn))),
      ]));
}

// ───────────── Loading / error / empty states ─────────────
// Reusable placeholders for wherever this app eventually calls a real
// data backend — a network fetch, a scoring service, etc.
class LoadingView extends StatelessWidget {
  final String message;
  const LoadingView({super.key, this.message = 'Loading…'});
  @override
  Widget build(BuildContext c) => Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: accent)),
        const SizedBox(height: 12),
        Text(message, style: mono(10)),
      ]));
}

class EmptyView extends StatelessWidget {
  final String message;
  final IconData icon;
  const EmptyView({super.key, this.message = 'Nothing found.', this.icon = Icons.search_off});
  @override
  Widget build(BuildContext c) => Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: muted, size: 26),
        const SizedBox(height: 10),
        Text(message, style: mono(10), textAlign: TextAlign.center),
      ]));
}

class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ErrorView({super.key, this.message = 'Something went wrong.', this.onRetry});
  @override
  Widget build(BuildContext c) => Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, color: Color(0xFFD9A441), size: 26),
        const SizedBox(height: 10),
        Text(message, style: mono(10), textAlign: TextAlign.center),
        if (onRetry != null) ...[
          const SizedBox(height: 10),
          TextButton(onPressed: onRetry, child: Text('RETRY', style: mono(10, accent))),
        ],
      ]));
}

// ───────────── Shared widgets ─────────────
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets pad;
  final bool stars; // false = no twinkling star dust inside this panel
  const Panel(
      {super.key,
      required this.child,
      this.pad = const EdgeInsets.all(14),
      this.stars = true});
  @override
  Widget build(BuildContext c) => Container(
      width: double.infinity,
      decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF241A13), Color(0xFF12141A), Color(0xFF080A0F)]),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accent.withAlpha(95)),
          boxShadow: [
            const BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 10)),
            BoxShadow(color: accent.withAlpha(46), blurRadius: 26, spreadRadius: 0.5),
            const BoxShadow(color: Color(0x14FFFFFF), blurRadius: 0, offset: Offset(0, 1)),
          ]),
      child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Stack(fit: StackFit.passthrough, children: [
            Positioned.fill(child: _PanelSky(stars: stars)),
            Padding(padding: pad, child: child),
          ])));
}

/// Animated "universe" layer inside panels: pulsing orange energy glow,
/// twinkling white star dust and a slow diagonal light sweep.
class _PanelSky extends StatefulWidget {
  final bool stars;
  const _PanelSky({this.stars = true});
  @override
  State<_PanelSky> createState() => _PanelSkyState();
}

class _PanelSkyState extends State<_PanelSky> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  static final List<List<double>> _dust = () {
    final r = math.Random(5);
    return List.generate(
        46,
        (_) => [
              r.nextDouble(),
              r.nextDouble(),
              0.45 + r.nextDouble() * 0.5, // small stars only
              r.nextDouble() * 6.283,
              0.7 + r.nextDouble() * 1.8
            ]);
  }();

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 3600))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
      child: RepaintBoundary(
          child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) => CustomPaint(painter: _PanelSkyPainter(_dust, _c.value * 3600, showStars: widget.stars)))));
}

class _PanelSkyPainter extends CustomPainter {
  final List<List<double>> dust;
  final double t;
  final bool showStars;
  _PanelSkyPainter(this.dust, this.t, {this.showStars = true});

  void _haze(Canvas cv, Offset o, double rad, Color col, int a) => cv.drawCircle(
      o,
      rad,
      Paint()
        ..shader = RadialGradient(colors: [col.withAlpha(a), Colors.transparent])
            .createShader(Rect.fromCircle(center: o, radius: rad)));

  @override
  void paint(Canvas cv, Size s) {
    final pulse = 0.5 + 0.5 * math.sin(t * 1.4);
    final drift = 0.5 + 0.5 * math.sin(t * 0.45);
    final drift2 = 0.5 + 0.5 * math.sin(t * 0.33 + 2.0);
    final big = math.max(s.width, s.height);
    // moderate warm glow in the corners
    _haze(cv, Offset.zero, big * 0.55, accent, (36 + 34 * pulse).round());
    _haze(cv, Offset(s.width, s.height), big * 0.45, const Color(0xFFFFB27A), (18 + 20 * pulse).round());
    // soft, slowly drifting white nebula light
    _haze(cv, Offset(s.width * (0.40 + 0.25 * drift), s.height * (0.35 + 0.2 * drift2)),
        big * 0.34, Colors.white, (12 + 14 * drift).round());
    _haze(cv, Offset(s.width * (0.75 - 0.2 * drift2), s.height * (0.7 - 0.2 * drift)),
        big * 0.26, const Color(0xFFDCE6FF), (8 + 12 * drift2).round());

    // slow diagonal light sweep
    final x = ((t * 0.09) % 1.8 - 0.4) * s.width;
    final bw = math.max(40.0, s.width * 0.16);
    cv.save();
    cv.clipRect(Offset.zero & s);
    cv.translate(x, 0);
    cv.transform((Matrix4.identity()..setEntry(0, 1, -0.5)).storage);
    final band = Rect.fromLTWH(0, -4, bw, s.height + 8);
    cv.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(colors: [
            Colors.white.withAlpha(0),
            Colors.white.withAlpha(22),
            Colors.white.withAlpha(0)
          ]).createShader(band));
    cv.restore();

    for (var i = 0; showStars && i < dust.length; i++) {
      final st = dust[i];
      final tw = 0.5 + 0.5 * math.sin(t * st[4] + st[3]);
      final o = Offset(st[0] * s.width, st[1] * s.height);
      final col = i.isEven ? Colors.white : const Color(0xFFFFE2C8);
      cv.drawCircle(o, st[2] * 2.4, Paint()..color = col.withAlpha((8 + 22 * tw).round()));
      cv.drawCircle(o, st[2] * 0.8, Paint()..color = col.withAlpha((90 + 165 * tw).round()));
    }
  }

  @override
  bool shouldRepaint(covariant _PanelSkyPainter old) => old.t != t;
}

/// Deep-space backdrop: warm nebula glows + twinkling white stars with
/// shiny 4-point sparkles (NASA-style night sky).
class SpaceBackdrop extends StatefulWidget {
  final Alignment glowAt;
  final int count;
  const SpaceBackdrop({super.key, this.glowAt = Alignment.center, this.count = 120});
  @override
  State<SpaceBackdrop> createState() => _SpaceBackdropState();
}

class _SpaceBackdropState extends State<SpaceBackdrop> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<List<double>> _s;

  @override
  void initState() {
    super.initState();
    final r = math.Random(21);
    // x, y, size, phase, speed
    _s = List.generate(
        (widget.count * 0.5).round(), // moderate amount
        (_) => [
              r.nextDouble(),
              r.nextDouble(),
              0.7 + r.nextDouble() * 0.6, // small dot-like stars
              r.nextDouble() * 6.283,
              0.6 + r.nextDouble() * 1.9
            ]);
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 3600))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
      child: RepaintBoundary(
          child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) => CustomPaint(
                  size: Size.infinite,
                  painter: _SpacePainter(_s, _c.value * 3600, widget.glowAt)))));
}

class _SpacePainter extends CustomPainter {
  final List<List<double>> stars;
  final double t;
  final Alignment glowAt;
  _SpacePainter(this.stars, this.t, this.glowAt);

  void _haze(Canvas cv, Offset o, double rad, Color col, int a) => cv.drawCircle(
      o,
      rad,
      Paint()
        ..shader = RadialGradient(colors: [col.withAlpha(a), Colors.transparent])
            .createShader(Rect.fromCircle(center: o, radius: rad)));

  @override
  void paint(Canvas cv, Size s) {
    final big = s.longestSide;
    final g = Offset(s.width * (glowAt.x + 1) / 2, s.height * (glowAt.y + 1) / 2);
    _haze(cv, g, big * 0.55, accent, 74);
    _haze(cv, g, big * 0.28, const Color(0xFFFFB27A), 46);
    _haze(cv, Offset(s.width * 0.08, s.height * 0.1), big * 0.38, const Color(0xFFFFB27A), 34);
    _haze(cv, Offset(s.width * 0.96, s.height * 0.88), big * 0.42, accent, 40);
    _haze(cv, Offset(s.width * 0.85, s.height * 0.08), big * 0.28, const Color(0xFFB8BCC8), 18);

    for (var i = 0; i < stars.length; i++) {
      final st = stars[i];
      final tw = 0.5 + 0.5 * math.sin(t * st[4] + st[3]);
      final o = Offset(st[0] * s.width, st[1] * s.height);
      final col = i % 3 == 0 ? const Color(0xFFFFE2C8) : Colors.white;
      // soft white glow around each dot, then the bright dot itself
      cv.drawCircle(
          o,
          st[2] * 3.2,
          Paint()
            ..color = col.withAlpha((22 + 38 * tw).round())
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5));
      cv.drawCircle(o, st[2] * 0.9, Paint()..color = col.withAlpha((140 + 115 * tw).round()));
    }
  }

  @override
  bool shouldRepaint(covariant _SpacePainter old) => old.t != t;
}

class Btn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool primary;
  const Btn(this.label, this.onTap, {super.key, this.primary = true});
  @override
  State<Btn> createState() => _BtnState();
}

class _BtnState extends State<Btn> with SingleTickerProviderStateMixin {
  late final AnimationController _shine =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  bool _busy = false;

  @override
  void dispose() {
    _shine.dispose();
    super.dispose();
  }

  void _flash() {
    if (!_shine.isAnimating) _shine.forward(from: 0);
  }

  // A white shine sweeps across the button, then the action runs.
  void _tap() {
    if (_busy) return;
    _busy = true;
    _shine.forward(from: 0);
    Future.delayed(const Duration(milliseconds: 280), () {
      _busy = false;
      if (mounted) widget.onTap();
    });
  }

  @override
  Widget build(BuildContext c) {
    final primary = widget.primary;
    return MouseRegion(
        onEnter: (_) => _flash(),
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: Ink(
              decoration: BoxDecoration(
                gradient: primary
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFF0955E), accent])
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF151C29), Color(0xFF0C1119)]),
                borderRadius: BorderRadius.circular(12),
                border: primary ? null : Border.all(color: line),
                boxShadow: primary
                    ? [BoxShadow(color: accent.withAlpha(110), blurRadius: 18, offset: const Offset(0, 8))]
                    : const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 5))],
              ),
              child: Stack(fit: StackFit.expand, children: [
                InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: _tap,
                    child: Center(
                        child: Text(widget.label,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                letterSpacing: 1,
                                color: primary ? Colors.black : fg)))),
                Positioned.fill(
                    child: IgnorePointer(
                        child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: CustomPaint(painter: _ShinePainter(_shine))))),
              ]),
            ),
          ),
        ));
  }
}

/// Slanted white shine band that crosses the button in a fraction of a second.
class _ShinePainter extends CustomPainter {
  final Animation<double> a;
  _ShinePainter(this.a) : super(repaint: a);
  @override
  void paint(Canvas cv, Size s) {
    final v = a.value;
    if (v <= 0 || v >= 1) return;
    final p = Curves.easeInOut.transform(v);
    const bw = 70.0;
    final x = -bw - 30 + p * (s.width + bw + 60);
    cv.save();
    cv.clipRect(Offset.zero & s);
    cv.translate(x, 0);
    cv.transform((Matrix4.identity()..setEntry(0, 1, -0.5)).storage);
    final band = Rect.fromLTWH(0, -4, bw, s.height + 8);
    cv.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(colors: [
            Colors.white.withAlpha(0),
            Colors.white.withAlpha(215),
            Colors.white.withAlpha(0)
          ]).createShader(band));
    cv.restore();
  }

  @override
  bool shouldRepaint(covariant _ShinePainter old) => false;
}

class Tag extends StatelessWidget {
  final String text;
  final Color color;
  final bool filled;
  const Tag(this.text, {super.key, this.color = muted, this.filled = false});
  @override
  Widget build(BuildContext c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
          color: filled ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: filled ? color : line),
          boxShadow: filled
              ? [BoxShadow(color: color.withAlpha(110), blurRadius: 10, offset: const Offset(0, 4))]
              : null),
      child: Text(text, style: mono(10, filled ? Colors.black : color)));
}

/// Page frame with "● GEOX" top bar.
Widget frame(BuildContext c, String section, Widget body,
        {bool back = false, Widget? backdrop, bool account = true}) =>
    Scaffold(
      drawer: const GeoXDrawer(),
      body: _withBackdrop(
        backdrop,
        SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.only(bottom: 14),
              decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: line, width: 1))),
              child: Row(children: [
                const _MenuButton(),
                const SizedBox(width: 10),
                if (back)
                  GestureDetector(
                      onTap: () => Navigator.pop(c),
                      child: Container(
                          margin: const EdgeInsets.only(right: 10),
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                              color: card,
                              shape: BoxShape.circle,
                              border: Border.all(color: line),
                              boxShadow: const [
                                BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 3))
                              ]),
                          child: const Icon(Icons.arrow_back, size: 16))),
                const Expanded(
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: GlowLogo(height: 48)))),
                _HomeAndAccount(showAccount: account),
              ]),
            ),
            const SizedBox(height: 16),
            Expanded(child: body),
          ]),
        ),
      )),
    );

Widget _withBackdrop(Widget? backdrop, Widget content) => backdrop == null
    ? content
    : Stack(fit: StackFit.expand, children: [Positioned.fill(child: backdrop), content]);

void go(BuildContext c, Widget w) => goNav(Navigator.of(c), w);

/// Pushes [w] with the zoom transition using an explicit navigator.
void goNav(NavigatorState nav, Widget w) => nav.push(
    PageRouteBuilder<void>(
      settings: RouteSettings(name: _titleFor(w)),
      transitionDuration: const Duration(milliseconds: 480),
      reverseTransitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (_, __, ___) => w,
      transitionsBuilder: (_, anim, __, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        final fade = CurvedAnimation(parent: anim, curve: const Interval(0, .4));
        // Grows from where the primary button sits (bottom of the screen),
        // so the next page feels like it's zooming in from the tap.
        return FadeTransition(
          opacity: fade,
          child: ScaleTransition(
            alignment: Alignment.bottomCenter,
            scale: Tween<double>(begin: 0.55, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    ));

// ───────────── Navigation history + side menu ─────────────
/// Human-readable name for each page, used by the side menu's history list.
String _titleFor(Widget w) => switch (w) {
      HomeScreen() => 'Home',
      SelectorScreen() => 'Choose target',
      TargetScreen(:final name) => 'Target · $name',
      MainShell(:final targetName) => 'Analogues · $targetName',
      SiteDetail(:final site) => 'Site · ${site.name}',
      CompareScreen() => 'Compare',
      PrioritiesScreen() => 'What matters most',
      SciencePage() => 'How it works',
      GlossaryScreen() => 'Glossary',
      ShortlistScreen() => 'Shortlist',
      OpenTargetLoader() => 'Analogues · Custom',
      LoginScreen() => 'Log in',
      RegisterScreen() => 'Register',
      ProfileScreen() => 'Profile',
      AskGeoXPage() => 'Ask GeoX',
      _ => 'Page',
    };

/// Last target the user picked, so the side menu can jump straight back in.
class _SelectorTargetIds {
  static const ids = {
    'Jezero Crater': 'mars_jezero',
    'Gale Crater': 'mars_gale',
    'Elysium Planitia': 'mars_elysium',
    'Meridiani Planum': 'mars_meridiani',
    'Chryse Planitia': 'mars_chryse',
    'Olympus Mons': 'mars_olympus',
    'Arcadia Planitia': 'mars_arcadia',
    'Utopia Planitia': 'mars_utopia',
    'Deuteronilus Mensae': 'mars_deuteronilus',
    'Planum Boreum': 'mars_planum_boreum',
    'Lunar South Pole': 'moon_south_pole',
    'Shackleton Crater': 'moon_shackleton',
    'Connecting Ridge': 'moon_connecting_ridge',
    'Malapert Massif': 'moon_malapert',
    'Haworth': 'moon_haworth',
    'de Gerlache Rim': 'moon_de_gerlache',
    'Cabeus Crater': 'moon_cabeus',
    'Peary Crater': 'moon_peary',
    'Mare Tranquillitatis Pit': 'moon_tranquillitatis',
    'Taurus-Littrow Valley': 'moon_taurus_littrow',
  };
  static String? of(String name) => ids[name];
}

class Session {
  static String targetName = 'Jezero Crater';
  static String planet = 'MARS';
}

/// Priorities the user pressed SAVE on (kept in memory for this session).
class SavedPriorities {
  static int preset = 0;
  static List<double> weights = [.40, .15, .25, .10, .10];
  static bool hasSaved = false;

  /// Bumped on every save or reset so open result pages re-order themselves.
  static final ValueNotifier<int> version = ValueNotifier<int>(0);

  static const _key = 'geox_priorities';

  /// Writes the current priorities to this device (or removes them).
  static Future<void> persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!hasSaved) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, jsonEncode({'preset': preset, 'weights': weights}));
      }
    } catch (e) {
      debugPrint('Priorities: could not save: $e');
    }
  }

  /// Reads them back at start-up. Anything unexpected is ignored.
  static Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final w = [for (final x in (m['weights'] as List<dynamic>)) (x as num).toDouble()];
      if (w.length != weights.length) return;
      final pr = (m['preset'] as num).toInt();
      if (pr < 0 || pr > 4) return;
      weights = w;
      preset = pr;
      hasSaved = true;
    } catch (e) {
      debugPrint('Priorities: could not load: $e');
    }
  }
}

/// Tracks the stack of open pages so the side menu can jump back to any of them.
class NavHistory extends NavigatorObserver {
  NavHistory._();
  static final NavHistory instance = NavHistory._();
  final List<Route<dynamic>> _stack = [];

  /// Open pages, oldest first (dialogs and sheets are ignored).
  List<Route<dynamic>> get pages =>
      _stack.whereType<PageRoute<dynamic>>().toList();

  static String labelOf(Route<dynamic> r) {
    final n = r.settings.name;
    return (n == null || n == '/') ? 'Home' : n;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.add(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.remove(route);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _stack.remove(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    final i = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (i >= 0) {
      _stack[i] = newRoute;
    } else {
      _stack.add(newRoute);
    }
  }
}

/// Round "three lines" button in the top bar that opens the side menu.
class _MenuButton extends StatefulWidget {
  const _MenuButton();
  @override
  State<_MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<_MenuButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => Tooltip(
      message: 'Menu & page history',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => Scaffold.of(context).openDrawer(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
                color: card,
                shape: BoxShape.circle,
                border: Border.all(color: _hover ? accent : line),
                boxShadow: _hover
                    ? [BoxShadow(color: accent.withAlpha(90), blurRadius: 10)]
                    : null),
            child: Icon(Icons.menu, size: 18, color: _hover ? accent : fg),
          ),
        ),
      ));
}

/// Side menu: every page opened so far (tap to jump straight back to it)
/// plus shortcuts to the main areas of the app.
class GeoXDrawer extends StatelessWidget {
  const GeoXDrawer({super.key});

  void _open(BuildContext ctx, Widget page) {
    final nav = Navigator.of(ctx);
    nav.pop(); // close the menu
    goNav(nav, page);
  }

  Widget _head(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(t, style: mono(9, accent)));

  Widget _tile(IconData icon, String label, VoidCallback onTap) => ListTile(
      dense: true,
      hoverColor: accent.withAlpha(30),
      leading: Icon(icon, size: 18, color: muted),
      title: Text(label, style: mono(11, fg)),
      onTap: onTap);

  Widget _histTile(NavigatorState nav, Route<dynamic> r, bool isCurrent) =>
      ListTile(
          dense: true,
          selected: isCurrent,
          selectedTileColor: accent.withAlpha(24),
          hoverColor: accent.withAlpha(30),
          leading: Icon(isCurrent ? Icons.radio_button_checked : Icons.undo,
              size: 18, color: isCurrent ? accent : muted),
          title: Text(NavHistory.labelOf(r),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(11, isCurrent ? accent : fg)),
          subtitle: Text(isCurrent ? 'YOU ARE HERE' : 'TAP TO GO BACK HERE',
              style: mono(8)),
          onTap: () {
            nav.pop(); // close the menu
            if (!isCurrent) nav.popUntil((x) => identical(x, r));
          });

  @override
  Widget build(BuildContext context) {
    final nav = Navigator.of(context);
    final pages = NavHistory.instance.pages.reversed.toList(); // newest first
    final signedIn = Auth.user.value != null;
    return Drawer(
      backgroundColor: bg,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
              child: Row(children: [
                const GlowLogo(height: 36),
                const Spacer(),
                IconButton(
                    icon: const Icon(Icons.close, color: muted, size: 20),
                    onPressed: () => nav.pop()),
              ])),
          const Divider(color: line, height: 1),
          Expanded(
              child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                _head('PAGES YOU OPENED'),
                for (var i = 0; i < pages.length; i++)
                  _histTile(nav, pages[i], i == 0),
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Divider(color: line, height: 1)),
                _head('JUMP TO'),
                _tile(Icons.home_outlined, 'HOME', () {
                  nav.pop();
                  nav.popUntil((r) => r.isFirst);
                }),
                _tile(Icons.public, 'CHOOSE TARGET',
                    () => _open(context, const SelectorScreen())),
                _tile(Icons.travel_explore, 'DISCOVER',
                    () => _open(context, MainShell(targetName: Session.targetName, planet: Session.planet))),
                _tile(Icons.gps_fixed, 'REVERSE MODE',
                    () => _open(context, MainShell(targetName: Session.targetName, planet: Session.planet, initialTab: 1))),
                _tile(Icons.bar_chart, 'TRENDS',
                    () => _open(context, MainShell(targetName: Session.targetName, planet: Session.planet, initialTab: 2))),
                _tile(Icons.tune, 'WHAT MATTERS MOST',
                    () => _open(context, const PrioritiesScreen())),
                _tile(Icons.bookmark_border, 'SHORTLIST',
                    () => _open(context, const ShortlistScreen())),
                _tile(Icons.forum_outlined, 'ASK GEOX',
                    () => _open(context, AskGeoXPage(targetName: Session.targetName))),
                _tile(Icons.science_outlined, 'HOW IT WORKS',
                    () => _open(context, const SciencePage(standalone: true))),
                _tile(Icons.menu_book_outlined, 'GLOSSARY',
                    () => _open(context, const GlossaryScreen())),
                _tile(Icons.person_outline,
                    signedIn ? 'MY PROFILE' : 'LOG IN / REGISTER',
                    () => _open(context, signedIn ? const ProfileScreen() : const LoginScreen())),
              ])),
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text('TIP · SWIPE FROM THE LEFT EDGE TO OPEN THIS MENU',
                  style: mono(8))),
        ]),
      ),
    );
  }
}

// ───────────── Data provenance: sources + clickable chip ─────────────
class ProvSource {
  final String name, full, what, usedFor;
  const ProvSource(this.name, this.full, this.what, this.usedFor);
}

const kSourcesMain = [
  ProvSource('NASA', 'National Aeronautics and Space Administration',
      'The US space agency. Its missions and archives supply much of the Mars and Moon data.',
      'Measurements and imagery of the Mars and Moon target sites.'),
  ProvSource('ESA', 'European Space Agency',
      'Europe\'s space agency, which runs the Copernicus Earth-observation programme.',
      'Earth land-cover data (WorldCover) for the Earth side of the match.'),
  ProvSource('MODIS', 'Moderate Resolution Imaging Spectroradiometer',
      'An instrument on NASA\'s Terra and Aqua satellites that images the whole Earth every day or two.',
      'Land surface temperature (thermal similarity) and vegetation greenness over the years.'),
  ProvSource('MOLA', 'Mars Orbiter Laser Altimeter',
      'A laser altimeter on NASA\'s Mars Global Surveyor that measured the height of the Martian surface.',
      'Roughness of Mars targets (terrain similarity). Elevation is not scored: heights use a different reference on each world.'),
  ProvSource('WORLDCOVER', 'ESA WorldCover',
      'A global land-cover map at 10 m detail showing bare ground, vegetation, water and more.',
      'Bare-ground similarity: the share of surface with little or no plant cover.'),
];

const kSourcesMore = [
  ProvSource('GOOGLE EARTH ENGINE', 'Google Earth Engine',
      'A cloud platform for analysing satellite data at planetary scale.',
      'Sampling the measured conditions of the Earth sites.'),
  ProvSource('NASA TREK', 'NASA Trek',
      'A NASA web portal for browsing maps and imagery of the Moon, Mars and other worlds.',
      'Imagery tiles of the Mars and Moon targets.'),
  ProvSource('LOLA', 'Lunar Orbiter Laser Altimeter',
      'A laser altimeter on NASA\'s Lunar Reconnaissance Orbiter that measures the height of the Moon\'s surface.',
      'Roughness of lunar targets (terrain similarity). Elevation is not scored for the same reason.'),
  ProvSource('DIVINER', 'Diviner Lunar Radiometer',
      'An infrared radiometer on the Lunar Reconnaissance Orbiter that measures surface temperature.',
      'Thermal conditions of lunar targets, including cold shadowed craters.'),
  ProvSource('CTX', 'Context Camera',
      'A camera on NASA\'s Mars Reconnaissance Orbiter that images Mars at about 6 m per pixel.',
      'Visual imagery of Mars targets.'),
  ProvSource('DINOV2', 'DINOv2',
      'A self-supervised vision model from Meta AI that turns a picture into a numeric fingerprint.',
      'The visual similarity score, used frozen with no extra training.'),
];

/// Pill that glows and shows a pointer on hover, and stays lit once selected.
class ProvenanceChip extends StatefulWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  const ProvenanceChip(
      {super.key, required this.text, required this.onTap, this.selected = false});
  @override
  State<ProvenanceChip> createState() => _ProvenanceChipState();
}

class _ProvenanceChipState extends State<ProvenanceChip> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    final lit = on || _hover;
    return Tooltip(
      message: on ? 'Tap to close' : 'Tap for details',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _hover && !on ? 1.06 : 1.0,
            duration: const Duration(milliseconds: 140),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                  color: on
                      ? accent
                      : (_hover ? accent.withAlpha(40) : Colors.transparent),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: lit ? accent : line),
                  boxShadow: lit
                      ? [
                          BoxShadow(
                              color: accent.withAlpha(on ? 110 : 80),
                              blurRadius: 12,
                              offset: const Offset(0, 3))
                        ]
                      : null),
              child: Text(widget.text,
                  style: mono(10, on ? Colors.black : (_hover ? accent : muted))),
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────── 1. Home ─────────────
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext c) => frame(
      c,
      'HOME',
      backdrop: const SpaceBackdrop(glowAt: Alignment(0, -0.35), count: 140),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Expanded(child: Center(child: RotatingPlanet())),
        Text.rich(TextSpan(style: head(40), children: [
          const TextSpan(text: 'DISCOVER\nMOON & MARS\n'),
          TextSpan(text: 'ANALOGS.', style: head(40, accent)),
        ])),
        const SizedBox(height: 12),
        const Text(
            'Discover terrestrial environments that resemble the Moon and Mars — and see how those similarities are changing over time.',
            style: TextStyle(color: muted, height: 1.4)),
        const SizedBox(height: 20),
        Btn('DISCOVER MOON & MARS ANALOGS →', () => go(c, const SelectorScreen())),
        const SizedBox(height: 10),
        Btn('HOW IT WORKS', () => go(c, const SciencePage(standalone: true)),
            primary: false),
        const SizedBox(height: 20),
      ]));
}

/// Photoreal, slowly-rotating 3D Mars. A procedural surface map (albedo
/// regions, craters, Valles-style canyon, polar caps) is generated once off
/// the UI thread, wrapped onto a lit sphere mesh, and surrounded by a bright
/// white corona and an orbiting white light beam.
class RotatingPlanet extends StatefulWidget {
  const RotatingPlanet({super.key});
  @override
  State<RotatingPlanet> createState() => _RotatingPlanetState();
}

class _RotatingPlanetState extends State<RotatingPlanet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  ui.Image? _tex;
  ui.ImageShader? _shader;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 60))
      ..repeat();
    _buildTexture();
  }

  Future<void> _buildTexture() async {
    final bytes = await compute(_marsTexturePixels, 0);
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        bytes, _kTexW, _kTexH, ui.PixelFormat.rgba8888, done.complete);
    final img = await done.future;
    if (!mounted) {
      img.dispose();
      return;
    }
    setState(() {
      _tex = img;
      _shader = ui.ImageShader(img, TileMode.clamp, TileMode.clamp,
          Matrix4.identity().storage);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _shader?.dispose();
    _tex?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => SizedBox(
            width: 190,
            height: 190,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(
                  child: CustomPaint(
                      painter: _PlanetGlowPainter(_ctrl.value, front: false))),
              Positioned.fill(
                  child: CustomPaint(
                      painter: MarsPainter(_ctrl.value * 2 * math.pi, _shader))),
              Positioned.fill(
                  child: CustomPaint(
                      painter: _PlanetGlowPainter(_ctrl.value, front: true))),
            ]),
          ));
}

/// White corona + light beam around the planet (drawn behind and in front).
class _PlanetGlowPainter extends CustomPainter {
  final double t;
  final bool front;
  _PlanetGlowPainter(this.t, {required this.front});

  @override
  void paint(Canvas cv, Size s) {
    final c = s.center(Offset.zero);
    final r = s.shortestSide / 2;
    front ? _front(cv, c, r) : _back(cv, c, r);
  }

  void _back(Canvas cv, Offset c, double r) {
    // Warm ambient corona in the app's orange.
    cv.drawCircle(
        c,
        r * 2.6,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xFFFF9A5C).withAlpha(150),
              accent.withAlpha(66),
              Colors.transparent
            ],
            stops: const [0.38, 0.62, 1.0],
          ).createShader(Rect.fromCircle(center: c, radius: r * 2.6)));
    // White-hot bloom on the sun side.
    final hc = c + Offset(-r * 0.62, -r * 0.66);
    cv.drawCircle(
        hc,
        r * 1.35,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Colors.white.withAlpha(150),
              const Color(0xFFFFC9A0).withAlpha(60),
              Colors.transparent
            ],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(Rect.fromCircle(center: hc, radius: r * 1.35)));
    // Soft white corona hugging the whole limb.
    cv.drawCircle(
        c,
        r * 1.03,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.14
          ..color = Colors.white.withAlpha(95)
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, r * 0.14));
  }

  void _front(Canvas cv, Offset c, double r) {
    final rect = Rect.fromCircle(center: c, radius: r * 0.995);
    // Tapered white crescent on the sun-lit (upper-left) limb.
    const sweeps = [0.80, 0.55, 0.30];
    const alphas = [70, 110, 160];
    for (var i = 0; i < 3; i++) {
      final sw = math.pi * sweeps[i];
      final start = math.pi * 1.25 - sw / 2;
      cv.drawArc(
          rect,
          start,
          sw,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * (0.10 - 0.03 * i)
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withAlpha(alphas[i])
            ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, r * 0.06));
    }
    cv.drawArc(
        rect,
        math.pi * 1.25 - math.pi * 0.28,
        math.pi * 0.56,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withAlpha(240));
    // Faint full rim.
    cv.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = Colors.white.withAlpha(50));
    // Orbiting white light beam with a fading tail.
    final oa = t * 6 * math.pi;
    const tail = 1.2;
    final orbit = Rect.fromCircle(center: c, radius: r * 1.015);
    final beam = ui.Gradient.sweep(
        Offset.zero,
        [Colors.white.withAlpha(0), Colors.white],
        null,
        TileMode.clamp,
        0.0,
        tail,
        (Matrix4.identity()
              ..translate(c.dx, c.dy)
              ..rotateZ(oa))
            .storage);
    cv.drawArc(
        orbit,
        oa,
        tail,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.07
          ..strokeCap = StrokeCap.round
          ..shader = beam
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, r * 0.05));
    cv.drawArc(
        orbit,
        oa,
        tail,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..shader = beam);
    final head = c + Offset(math.cos(oa + tail), math.sin(oa + tail)) * (r * 1.015);
    cv.drawCircle(
        head,
        r * 0.07,
        Paint()
          ..color = Colors.white
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, r * 0.05));
    cv.drawCircle(head, 2.2, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _PlanetGlowPainter old) => old.t != t;
}

class SelectorScreen extends StatefulWidget {
  const SelectorScreen({super.key});
  @override
  State<SelectorScreen> createState() => _SelectorState();
}

class _SelectorState extends State<SelectorScreen> {
  int planet = 0; // 0 = Mars, 1 = Moon, 2 = Custom coordinates
  int marsSel = 0;
  int moonSel = 0;
  int customTargetPlanet = 0; // which world the custom coords apply to
  String terrain = 'crater_floor';
  bool shadowed = false;
  int _planetBeforeCustom = 0; // restored when Custom Coordinates is cancelled
  final _latCtrl = TextEditingController();
  final _lonCtrl = TextEditingController();

  static const _terrains = [
    ('flat_plain', 'FLAT PLAIN'),
    ('crater_floor', 'CRATER FLOOR'),
    ('rough', 'RUGGED HIGHLAND'),
    ('canyon', 'CANYON / SCARP'),
    ('crater_wall', 'CRATER WALL'),
  ];

  static const marsList = [
    ('Jezero Crater', '18.4°N 77.5°E'),
    ('Gale Crater', '4.6°S 137.4°E'),
    ('Elysium Planitia', '4.5°N 135.6°E'),
    ('Meridiani Planum', '1.9°S 5.5°W'),
    ('Chryse Planitia', '22.7°N 48.0°W'),
    ('Olympus Mons', '18.6°N 133.8°W'),
    ('Arcadia Planitia', '47.2°N 175.7°W'),
    ('Utopia Planitia', '46.7°N 117.5°E'),
    ('Deuteronilus Mensae', '43.9°N 23.9°E'),
    ('Planum Boreum', '85.0°N 0.0°E'),
  ];
  static const moonList = [
    ('Lunar South Pole', '89.9°S 0.0°E'),
    ('Shackleton Crater', '89.7°S 129.8°E'),
    ('Connecting Ridge', '89.5°S 137.3°W'),
    ('Malapert Massif', '86.0°S 2.7°E'),
    ('Haworth', '87.5°S 4.6°W'),
    ('de Gerlache Rim', '88.5°S 87.1°W'),
    ('Cabeus Crater', '85.3°S 42.1°W'),
    ('Peary Crater', '88.6°N 33.0°E'),
    ('Mare Tranquillitatis Pit', '8.3°N 33.2°E'),
    ('Taurus-Littrow Valley', '20.2°N 30.8°E'),
  ];


  @override
  void dispose() {
    _latCtrl.dispose();
    _lonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final marsPicked = marsList[marsSel];
    final moonPicked = moonList[moonSel];
    return frame(
        c,
        'CHOOSE TARGET',
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('STEP 01 / 03', style: mono(10)),
          const SizedBox(height: 8),
          Text('Choose a\ntarget world', style: head(30)),
          const SizedBox(height: 8),
          const Text('Select the world whose environment you want to find on Earth.',
              style: TextStyle(color: muted)),
          const SizedBox(height: 18),
          Expanded(
            child: ListView(children: [
              _planetPanel(
                expanded: planet == 0,
                onTapHeader: () => setState(() => planet = 0),
                avatarGradient: const [Color(0xFFE9A26B), Color(0xFFB5501F)],
                name: 'MARS',
                subtitle: 'THE RED PLANET · ${marsList.length} SITES',
                list: marsList,
                sel: marsSel,
                onSelect: (i) => setState(() => marsSel = i),
              ),
              const SizedBox(height: 10),
              _planetPanel(
                expanded: planet == 1,
                onTapHeader: () => setState(() => planet = 1),
                avatarGradient: const [Color(0xFFDDE3EC), Color(0xFF8A909C)],
                name: 'MOON',
                subtitle: "EARTH'S SATELLITE · ${moonList.length} SITES",
                list: moonList,
                sel: moonSel,
                onSelect: (i) => setState(() => moonSel = i),
              ),
              const SizedBox(height: 10),
              _customTargetPanel(c),
            ]),
          ),
          const SizedBox(height: 10),
          if (planet == 2)
            Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                alignment: Alignment.center,
                child: Text('ENTER COORDINATES ABOVE ↑', style: mono(10)))
          else
            Btn('EXPLORE PLANETARY ANALOGUES →', () {
              final picked = planet == 0 ? marsPicked : moonPicked;
              go(
                  c,
                  TargetScreen(
                      name: picked.$1,
                      coords: picked.$2,
                      planet: planet == 0 ? 'MARS' : 'MOON',
                      targetId: _SelectorTargetIds.of(picked.$1)));
            }),
          const SizedBox(height: 20),
        ]),
        back: true);
  }

  Widget _customTargetPanel(BuildContext c) {
    final expanded = planet == 2;
    return Panel(
        stars: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() {
          if (planet != 2) _planetBeforeCustom = planet;
          planet = 2;
        }),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: bg,
                border: Border.all(color: line)),
            child: const Icon(Icons.my_location, size: 16, color: teal),
          ),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('CUSTOM COORDINATES', style: mono(13, expanded ? accent : fg)),
            Text('ANY LAT / LON · MARS OR MOON', style: mono(9)),
          ]),
          const Spacer(),
          Icon(expanded ? Icons.check_circle : Icons.expand_more,
              color: expanded ? accent : muted, size: 20),
        ]),
      ),
      if (expanded) ...[
        const SizedBox(height: 16),
        Row(children: [
          for (var i = 0; i < 2; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() => customTargetPlanet = i),
              child: Tag(i == 0 ? 'MARS' : 'MOON',
                  color: accent, filled: customTargetPlanet == i),
            ),
          ],
        ]),
        const SizedBox(height: 12),
        Text('TERRAIN AT THIS POINT', style: mono(9)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final t in _terrains)
            GestureDetector(
              onTap: () => setState(() => terrain = t.$1),
              child: Tag(t.$2, color: accent, filled: terrain == t.$1),
            ),
        ]),
        if (customTargetPlanet == 1) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: Text(
                    shadowed
                        ? 'PERMANENTLY SHADOWED: ON (about -185 °C)'
                        : 'PERMANENTLY SHADOWED: OFF (sunlit model)',
                    style: mono(10, shadowed ? accent : muted))),
            Switch(
                value: shadowed,
                activeThumbColor: accent,
                onChanged: (v) => setState(() => shadowed = v)),
          ]),
          Text('Turn on only for a crater floor near a pole (latitude beyond 80°).',
              style: mono(9)),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: TextField(
            controller: _latCtrl,
            keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
            style: const TextStyle(color: fg, fontSize: 13),
            decoration: InputDecoration(
                labelText: 'Latitude',
                labelStyle: mono(9),
                hintText: 'e.g. 18.4',
                hintStyle: mono(9),
                filled: true,
                fillColor: bg,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: line))),
          )),
          const SizedBox(width: 10),
          Expanded(
              child: TextField(
            controller: _lonCtrl,
            keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
            style: const TextStyle(color: fg, fontSize: 13),
            decoration: InputDecoration(
                labelText: 'Longitude',
                labelStyle: mono(9),
                hintText: 'e.g. 77.7',
                hintStyle: mono(9),
                filled: true,
                fillColor: bg,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: line))),
          )),
        ]),
        const SizedBox(height: 14),
        Btn('USE THIS LOCATION →', () {
          final lat = double.tryParse(_latCtrl.text.trim());
          final lon = double.tryParse(_lonCtrl.text.trim());
          if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
            ScaffoldMessenger.of(c).showSnackBar(const SnackBar(
                content: Text(
                    'Enter a latitude from -90 to 90 and a longitude from -180 to 180.')));
            return;
          }
          final coords =
              '${lat.abs().toStringAsFixed(1)}°${lat >= 0 ? 'N' : 'S'} ${lon.abs().toStringAsFixed(1)}°${lon >= 0 ? 'E' : 'W'}';
          go(
              c,
              TargetScreen(
                  name: 'Custom Site',
                  coords: coords,
                  planet: customTargetPlanet == 0 ? 'MARS' : 'MOON',
                  query: OpenTargetQuery(
                      lat: lat,
                      lon: lon,
                      terrain: terrain,
                      shadowed: shadowed && customTargetPlanet == 1)));
        }),
        const SizedBox(height: 10),
        Btn('CANCEL', () {
          FocusScope.of(c).unfocus();
          setState(() {
            _latCtrl.clear();
            _lonCtrl.clear();
            customTargetPlanet = 0;
            terrain = 'crater_floor';
            shadowed = false;
            planet = _planetBeforeCustom;
          });
        }, primary: false),
      ],
    ]));
  }

  Widget _planetPanel({
    required bool expanded,
    required VoidCallback onTapHeader,
    required List<Color> avatarGradient,
    required String name,
    required String subtitle,
    required List<(String, String)> list,
    required int sel,
    required void Function(int) onSelect,
  }) =>
      Panel(
          stars: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTapHeader,
          child: Row(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: avatarGradient),
                  boxShadow: [
                    BoxShadow(color: avatarGradient.last.withAlpha(150), blurRadius: 10, offset: const Offset(0, 4))
                  ]),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: mono(13, expanded ? accent : fg)),
              Text(subtitle, style: mono(9)),
            ]),
            const Spacer(),
            Icon(expanded ? Icons.check_circle : Icons.expand_more,
                color: expanded ? accent : muted, size: 20),
          ]),
        ),
        if (expanded) ...[
          const SizedBox(height: 16),
          Text('SELECT TARGET SITE', style: mono(9)),
          const SizedBox(height: 8),
          for (var i = 0; i < list.length; i++)
            GestureDetector(
              onTap: () => onSelect(i),
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                decoration: BoxDecoration(
                    color: sel == i ? accent : bg,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: sel == i
                        ? [BoxShadow(color: accent.withAlpha(120), blurRadius: 10, offset: const Offset(0, 4))]
                        : null),
                child: Row(children: [
                  Text(list[i].$1,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: sel == i ? Colors.black : fg)),
                  const Spacer(),
                  Text(list[i].$2, style: mono(10, sel == i ? Colors.black : muted)),
                ]),
              ),
            ),
        ],
      ]));
}

// ───────────── 3. Target site ─────────────
class TargetScreen extends StatelessWidget {
  final String name, coords, planet;

  /// Set only for "Custom coordinates": the point is scored by the server.
  final OpenTargetQuery? query;

  /// Server id of a standard target (mars_jezero ...). When the server address is
  /// set, the ranking comes from the server; otherwise the bundled preview is used.
  final String? targetId;
  const TargetScreen(
      {super.key,
      required this.name,
      required this.coords,
      this.planet = 'MARS',
      this.query,
      this.targetId});
  @override
  Widget build(BuildContext c) {
    final isMoon = planet == 'MOON';
    final q = query;
    return frame(
      c,
      'TARGET',
      ListView(children: [
        Tag('● $planet  TARGET SITE', color: isMoon ? teal : accent),
        const SizedBox(height: 10),
        Text(name, style: head(32)),
        const SizedBox(height: 4),
        Text(
            (q != null || targetId != null)
                ? coords
                : (isMoon
                    ? '$coords · Ø 21 KM · PERMANENTLY SHADOWED'
                    : '$coords · Ø 45 KM · PALEOLAKE BASIN'),
            style: mono(9)),
        const SizedBox(height: 14),
        if (targetId != null)
          _TargetPicture(targetId: targetId!, isMoon: isMoon)
        else
        Container(
          height: 120,
          alignment: Alignment.bottomLeft,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isMoon
                      ? const [Color(0xFF6B7078), Color(0xFF2C2F35)]
                      : const [Color(0xFF8A4A2A), Color(0xFF5E2E18)]),
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 16, offset: Offset(0, 8))
              ]),
          child: Text('ILLUSTRATION · NOT A SATELLITE IMAGE',
              style: mono(9, Colors.white70)),
        ),
        const SizedBox(height: 14),
        if (targetId != null)
          _TargetFacts(targetId: targetId!)
        else
        Text(
            q != null
                ? 'A point you chose. GeoX models its conditions from its latitude and the terrain you picked, then compares them with the Earth sites.'
                : isMoon
                ? 'A permanently shadowed polar crater — airless, cratered, and extremely cold, with likely water ice deposits. NASA\'s Artemis missions are targeting it for long-term habitation.'
                : 'An ancient river delta and paleolake — cratered, basaltic, hyper-arid, and bare. NASA\'s Perseverance is exploring it now for signs of past life.',
            style: const TextStyle(color: muted, height: 1.4)),
        const SizedBox(height: 14),
        if (q == null && targetId == null) ...[
          Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('TARGET FINGERPRINT', style: mono(10, fg)),
            const FidelityRadar(values: [.8, .6, .9, .3, .7], labels: labels),
          ])),
          const SizedBox(height: 14),
        ],
        Btn('FIND EARTH ANALOGUES →', () {
          if (q != null) {
            go(c, OpenTargetLoader(query: q, name: name, planet: planet));
            return;
          }
          if (targetId != null) {
            go(c, OpenTargetLoader(targetId: targetId, name: name, planet: planet));
            return;
          }
          Session.targetName = name;
          Session.planet = planet;
          go(c, MainShell(targetName: name, planet: planet));
        }),
        const SizedBox(height: 20),
      ]),
      back: true,
    );
  }
}

/// The stored description and measured values of a standard target.
class _TargetFacts extends StatefulWidget {
  final String targetId;
  const _TargetFacts({required this.targetId});
  @override
  State<_TargetFacts> createState() => _TargetFactsState();
}

class _TargetFactsState extends State<_TargetFacts> {
  TargetInfo? _info;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    BundledTargets.targetInfo(widget.targetId).then((v) {
      if (mounted) setState(() => _info = v);
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
  }

  static String _cap(String t) =>
      t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);

  @override
  Widget build(BuildContext c) {
    final i = _info;
    if (i == null) {
      return _failed
          ? const Text('The stored values for this target could not be read.',
              style: TextStyle(color: muted))
          : const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: LoadingView());
    }
    final f = i.features;
    final rows = <(String, String, String)>[
      if (f['slope'] != null)
        ('Slope', f['slope']!.toStringAsFixed(1), i.confidence['slope'] ?? ''),
      if (f['roughness'] != null)
        ('Roughness', f['roughness']!.toStringAsFixed(0), i.confidence['roughness'] ?? ''),
      if (f['temperature'] != null)
        ('Surface temperature', '${f['temperature']!.toStringAsFixed(0)} °C',
            i.confidence['temperature'] ?? ''),
      if (f['temperature_variation'] != null)
        ('Day to night swing', '${f['temperature_variation']!.toStringAsFixed(0)} °C',
            i.confidence['temperature_variation'] ?? ''),
      if (f['ndvi'] != null)
        ('Vegetation (NDVI)', f['ndvi']!.toStringAsFixed(2), i.confidence['ndvi'] ?? ''),
      if (f['bare_ground'] != null)
        ('Bare ground', '${(f['bare_ground']! * 100).round()}%',
            i.confidence['bare_ground'] ?? ''),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${_cap(i.description)}.',
          style: const TextStyle(color: muted, height: 1.4)),
      const SizedBox(height: 14),
      Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('STORED VALUES FOR THIS TARGET', style: mono(10, fg)),
        const SizedBox(height: 8),
        for (final r in rows)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Expanded(child: Text(r.$1)),
                Text(r.$2, style: mono(12, accent)),
                SizedBox(
                    width: 78,
                    child: Text(r.$3.toUpperCase(),
                        textAlign: TextAlign.right, style: mono(8))),
              ])),
        const SizedBox(height: 6),
        Text(
            i.visualScoring
                ? 'Compared with satellite tiles as well as these values.'
                : 'This target\'s tile has no texture to compare, so it is scored on these values alone.',
            style: const TextStyle(color: muted, fontSize: 11, height: 1.4)),
      ])),
    ]);
  }
}

// ───────────── Main shell with bottom nav ─────────────
class MainShell extends StatefulWidget {
  final String targetName, planet;
  final int initialTab;

  /// Live results for a custom coordinate; null means the bundled preview list.
  final List<Site>? openSites;
  final List<String> notes;
  const MainShell(
      {super.key,
      this.targetName = 'Jezero Crater',
      this.planet = 'MARS',
      this.initialTab = 0,
      this.openSites,
      this.notes = const []});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  late int i = widget.initialTab;
  @override
  Widget build(BuildContext c) => PopScope(
      canPop: i == 0,
      // Requires Flutter 3.22+. On 3.19–3.21 use onPopInvoked: (didPop) {...}
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => i = 0);
      },
      child: Scaffold(
        body: IndexedStack(index: i, children: [
          DiscoverPage(
              targetName: widget.targetName,
              openSites: widget.openSites,
              notes: widget.notes),
          const ReversePage(),
          TrendPage(targetName: widget.targetName),
          const SciencePage(),
        ]),
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(boxShadow: [
            BoxShadow(color: Colors.black87, blurRadius: 20, offset: Offset(0, -6))
          ]),
          child: NavigationBar(
          backgroundColor: bg,
          indicatorColor: Colors.transparent,
          selectedIndex: i,
          onDestinationSelected: (v) => setState(() => i = v),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.home_outlined, color: muted),
                selectedIcon: Icon(Icons.home, color: accent),
                label: 'DISCOVER'),
            NavigationDestination(
                icon: Icon(Icons.gps_fixed, color: muted),
                selectedIcon: Icon(Icons.gps_fixed, color: accent),
                label: 'REVERSE'),
            NavigationDestination(
                icon: Icon(Icons.bar_chart, color: muted),
                selectedIcon: Icon(Icons.bar_chart, color: accent),
                label: 'TRENDS'),
            NavigationDestination(
                icon: Icon(Icons.person_outline, color: muted),
                selectedIcon: Icon(Icons.person, color: accent),
                label: 'SITES'),
          ],
        )),
      ));
}

// ───────────── 4. Discovery map ─────────────
class DiscoverPage extends StatefulWidget {
  final String targetName;
  final List<Site>? openSites;
  final List<String> notes;
  const DiscoverPage(
      {super.key,
      this.targetName = 'Jezero Crater',
      this.openSites,
      this.notes = const []});
  @override
  State<DiscoverPage> createState() => _DiscoverState();
}

class _DiscoverState extends State<DiscoverPage> {
  Category? filter; // null = ALL
  final _search = TextEditingController();
  String query = '';

  @override
  void initState() {
    super.initState();
    SavedPriorities.version.addListener(_onPriorities);
  }

  @override
  void dispose() {
    SavedPriorities.version.removeListener(_onPriorities);
    _search.dispose();
    super.dispose();
  }

  void _setFilter(Category? f) => setState(() => filter = f);

  List<Site> get _all {
    final base = widget.openSites ?? sites;
    if (widget.openSites != null && SavedPriorities.hasSaved) {
      return reRankSites(base, SavedPriorities.weights);
    }
    return base;
  }

  void _onPriorities() {
    if (mounted) setState(() {});
  }

  List<Site> get _filtered => _all.where((s) {
        final matchesCategory = filter == null || s.category == filter;
        final matchesQuery =
            query.isEmpty || s.name.toLowerCase().contains(query.toLowerCase());
        return matchesCategory && matchesQuery;
      }).toList();

  @override
  Widget build(BuildContext c) {
    final results = _filtered;
    return frame(
        c,
        'DISCOVERY',
        ListView(children: [
          if (widget.openSites != null)
            _LiveNote(widget.notes,
                bundled: widget.openSites!.isNotEmpty &&
                    widget.openSites!.first.source == 'bundle')
          else if (kPreviewData)
            const _PreviewNote(),
          if (widget.openSites != null && SavedPriorities.hasSaved)
            Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Panel(
                    stars: false,
                    child: Row(children: [
                      Expanded(
                          child: Text(
                              'RE-RANKED BY YOUR PRIORITIES · ${_PrioritiesState.presets[SavedPriorities.preset]} · THESE ${widget.openSites!.length} RESULTS ONLY',
                              style: mono(9, accent))),
                      GestureDetector(
                          onTap: () {
                            SavedPriorities.hasSaved = false;
                            SavedPriorities.persist();
                            SavedPriorities.version.value++;
                          },
                          child: Padding(
                              padding: const EdgeInsets.only(left: 10),
                              child: Text('RESET', style: mono(9, teal)))),
                    ]))),
          Text('EARTH ANALOGUES FOR', style: mono(9)),
          Row(children: [
            Expanded(
                child: Text(widget.targetName,
                    style: head(26, accent),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis)),
            IconButton(
                tooltip: 'Ask GeoX',
                icon: const Icon(Icons.forum_outlined, color: muted),
                onPressed: () => go(c, AskGeoXPage(targetName: widget.targetName))),
            IconButton(
                icon: const Icon(Icons.tune, color: muted),
                onPressed: () => go(c, const PrioritiesScreen())),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _search,
            onChanged: (v) => setState(() => query = v),
            style: const TextStyle(color: fg, fontSize: 13),
            decoration: InputDecoration(
                hintText: 'Search analog sites…',
                hintStyle: mono(10),
                prefixIcon: const Icon(Icons.search, color: muted, size: 18),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, color: muted, size: 16),
                        onPressed: () => setState(() {
                              _search.clear();
                              query = '';
                            })),
                filled: true,
                fillColor: card,
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: line))),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            GestureDetector(
                onTap: () => _setFilter(null),
                child: Tag('ALL', color: accent, filled: filter == null)),
            for (final cat in Category.values)
              if (_all.any((s) => s.category == cat))
              GestureDetector(
                  onTap: () => _setFilter(cat),
                  child: Tag(categoryLabel(cat), color: accent, filled: filter == cat)),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            height: 240,
            child: results.isEmpty
                ? EmptyView(
                    message:
                        'No analog sites match "$query"${filter != null ? ' in ${categoryLabel(filter!)}' : ''}.')
                : LayoutBuilder(
                    builder: (_, box) => Stack(children: [
                          Positioned.fill(
                              child: CustomPaint(painter: MapPainter())),
                          for (final s in results)
                            Positioned(
                              left: s.pos.dx * box.maxWidth - 20,
                              top: s.pos.dy * box.maxHeight - 20,
                              child: GestureDetector(
                                onTap: () => go(
                                    c,
                                    SiteDetail(
                                        site: s,
                                        targetName: widget.targetName)),
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: accent.withAlpha(50),
                                      boxShadow: [
                                        BoxShadow(
                                            color: accent.withAlpha(120),
                                            blurRadius: s.score / 4)
                                      ]),
                                  child: Text('${s.score}', style: mono(10, fg)),
                                ),
                              ),
                            ),
                        ]),
                  ),
          ),
          Panel(
              child: Column(children: [
            Row(children: [
              Text('TOP EARTH ANALOGUES', style: mono(10)),
              const Spacer(),
              Text('${results.length} OF ${_all.length}', style: mono(9)),
            ]),
            if (results.isEmpty)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text('No matches for the current filter.', style: mono(10))),
            for (var i = 0; i < results.length; i++)
              InkWell(
                onTap: () => go(
                    c,
                    SiteDetail(
                        site: results[i], targetName: widget.targetName)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(children: [
                    Text((i + 1).toString().padLeft(2, '0'), style: mono(10, accent)),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(results[i].name,
                            style: const TextStyle(fontWeight: FontWeight.w700))),
                    const SizedBox(width: 8),
                    Tag(results[i].tag,
                        color: results[i].tag == 'KNOWN' ? teal : const Color(0xFFD9A441)),
                    const SizedBox(width: 8),
                    Text('${results[i].score}',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
          ])),
          const SizedBox(height: 10),
          Btn('+ SUGGEST NEW ANALOG SITE', () => _openSuggestDialog(c), primary: false),
          const SizedBox(height: 24),
        ]),
        back: true);
  }

  void _openSuggestDialog(BuildContext c) {
    final nameCtrl = TextEditingController();
    final coordCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    Category cat = Category.desert;
    var sending = false;
    showDialog(
        context: c,
        builder: (dctx) => StatefulBuilder(
              builder: (dctx, setD) => Dialog(
                backgroundColor: card,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Suggest a new analog site', style: head(18))),
                    const SizedBox(height: 4),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Submitted candidates are reviewed before being confirmed.',
                            style: mono(9))),
                    const SizedBox(height: 14),
                    TextField(
                      controller: nameCtrl,
                      style: const TextStyle(color: fg, fontSize: 13),
                      decoration: InputDecoration(
                          labelText: 'Site name',
                          labelStyle: mono(9),
                          filled: true,
                          fillColor: bg,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: line))),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: coordCtrl,
                      style: const TextStyle(color: fg, fontSize: 13),
                      decoration: InputDecoration(
                          labelText: 'Location (e.g. 24.5°S 69.2°W or -24.5, -69.2)',
                          labelStyle: mono(9),
                          filled: true,
                          fillColor: bg,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: line))),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: noteCtrl,
                      maxLines: 2,
                      style: const TextStyle(color: fg, fontSize: 13),
                      decoration: InputDecoration(
                          labelText: 'Why does it match? (at least 10 characters)',
                          labelStyle: mono(9),
                          filled: true,
                          fillColor: bg,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: line))),
                    ),
                    const SizedBox(height: 12),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: Text('ENVIRONMENT', style: mono(9))),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final cCat in Category.values)
                        GestureDetector(
                          onTap: () => setD(() => cat = cCat),
                          child: Tag(categoryLabel(cCat), color: accent, filled: cat == cCat),
                        ),
                    ]),
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(
                          child: Btn('CANCEL', () => Navigator.pop(dctx), primary: false)),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Btn(sending ? 'SENDING…' : 'SUBMIT', () async {
                        if (sending) return;
                        void warn(String t) => ScaffoldMessenger.of(dctx)
                            .showSnackBar(SnackBar(content: Text(t)));
                        final name = nameCtrl.text.trim();
                        final why = noteCtrl.text.trim();
                        final pos = parseCoordinates(coordCtrl.text);
                        if (name.length < 2) {
                          warn('Give the site a name first.');
                          return;
                        }
                        if (pos == null) {
                          warn('Enter the location as 24.5°S 69.2°W or -24.5, -69.2.');
                          return;
                        }
                        if (why.length < 10) {
                          warn('Say why it matches, in at least 10 characters.');
                          return;
                        }
                        final token = await Auth.freshToken();
                        if (token == null) {
                          warn('Please log in first. Suggestions are tied to an account.');
                          return;
                        }
                        setD(() => sending = true);
                        try {
                          final note = await GeoXApi.suggestSite(
                              token: token,
                              name: name,
                              lat: pos.$1,
                              lon: pos.$2,
                              why: why,
                              category: cat.name);
                          if (dctx.mounted) Navigator.pop(dctx);
                          if (c.mounted) {
                            ScaffoldMessenger.of(c).showSnackBar(SnackBar(
                                content: Text('Submitted. $note')));
                          }
                        } catch (e) {
                          if (dctx.mounted) {
                            setD(() => sending = false);
                            warn(e is ApiException ? e.message : 'Could not send the suggestion.');
                          }
                        }
                      })),
                    ]),
                  ])),
                ),
              ),
            ));
  }
}

// ───────────── 5. Site detail + fidelity fingerprint ─────────────
class SiteDetail extends StatelessWidget {
  final Site site;
  final String targetName;
  const SiteDetail(
      {super.key, required this.site, this.targetName = 'Jezero Crater'});

  String _export(String fmt) {
    final f = [
      if (site.live && site.visual != null)
        {'feature': 'VISUAL', 'similarity': site.visual!.round()},
      for (var i = 0; i < site.radar.length; i++)
        site.live
            ? {
                'feature': site.axes[i],
                'similarity': (site.radar[i] * 100).round()
              }
            : {
                'feature': site.axes[i],
                'earth': (site.radar[i] * 100).round(),
                'target': targets[i]
              }
    ];
    if (fmt == 'JSON') {
      return jsonEncode({
        'site': site.name,
        'meta': site.meta,
        'status': site.tag,
        'targetName': targetName,
        'score': site.score,
        'previewData': kPreviewData && !site.live,
        'live': site.live,
        'features': f,
      });
    }
    if (fmt == 'CSV') {
      if (site.live) {
        return [
          'feature,similarity',
          for (final r in f) '${r['feature']},${r['similarity']}'
        ].join('\n');
      }
      return [
        'feature,earth,target',
        for (final r in f) '${r['feature']},${r['earth']},${r['target']}'
      ].join('\n');
    }
    return [
      'GEOX SITE REPORT',
      site.name,
      site.meta,
      'Matched against: $targetName',
      'Status: ${site.tag}',
      'Fidelity: ${site.score}',
      if (site.source == 'bundle')
        'NOTE: validated data bundled with the app. ${site.visual != null ? 'Environment plus visual similarity' : 'Environment only'}. Rescaled within this target, not an absolute measurement.'
      else if (site.live)
        'NOTE: live server score, environment only. Rescaled within this result, not an absolute measurement.'
      else if (kPreviewData)
        'NOTE: preview values, not from the validated dataset.',
      '',
      for (final r in f)
        site.live
            ? '${r['feature']}: similarity ${r['similarity']}'
            : '${r['feature']}: Earth ${r['earth']} vs target ${r['target']}',
      '',
      'Fused scores rank within one target and are not absolute measurements.',
    ].join('\n');
  }

  @override
  Widget build(BuildContext c) {
    String band(int v) => v >= 75 ? 'HIGH' : (v >= 50 ? 'MED' : 'LOW');
    int m(String k) => (site.mission[k] ?? 0).round();
    final uses = site.live
        ? [
            ('Rover mobility', m('rover'), band(m('rover'))),
            ('Geological fieldwork', m('geology'), band(m('geology'))),
            ('Astrobiology', m('astrobiology'), band(m('astrobiology'))),
            ('EVA testing', m('eva'), band(m('eva'))),
            ('ISRU research', m('isru'), band(m('isru'))),
          ]
        : [
            ('Rover mobility', 88, 'HIGH'),
            ('Geological fieldwork', 92, 'HIGH'),
            ('Astrobiology', 60, 'MED'),
            ('EVA testing', 58, 'MED'),
            ('ISRU research', 85, 'HIGH'),
          ];
    return frame(
        c,
        'SITE PROFILE',
        ListView(children: [
          if (site.live)
            Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Tag(
                        site.source == 'bundle'
                            ? (site.visual != null
                                ? '● VALIDATED DATA · ENVIRONMENT + VISUAL'
                                : '● VALIDATED DATA · ENVIRONMENT ONLY')
                            : '● LIVE SCORE · ENVIRONMENT ONLY',
                        color: teal)))
          else if (kPreviewData)
            const _PreviewNote(),
          Row(children: [
            Tag('● ${site.tag} ANALOGUE', color: teal),
            const SizedBox(width: 8),
            Tag(categoryLabel(site.category)),
            const Spacer(),
            GestureDetector(
              onTap: () => _showExportSheet(c),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: line)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.file_download_outlined, size: 13, color: muted),
                  const SizedBox(width: 5),
                  Text('EXPORT', style: mono(9)),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Text(site.name, style: head(32)),
          const SizedBox(height: 4),
          Text(site.meta, style: mono(9)),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child: Panel(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('FIDELITY', style: mono(9)),
              Text('${site.score}', style: head(40)),
            ]))),
            const SizedBox(width: 10),
            Expanded(
                child: Panel(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(site.live ? 'RANK' : 'ACCESS', style: mono(9)),
              const SizedBox(height: 10),
              Text(
                  site.live
                      ? site.meta.split(' · ').first.replaceFirst('RANK ', '#')
                      : 'Road · 4×4',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ]))),
          ]),
          const SizedBox(height: 18),
          Row(children: [
            Text('WHY IT MATCHES', style: mono(10, fg)),
            const SizedBox(width: 6),
            GestureDetector(
                onTap: () => go(c, const GlossaryScreen()),
                child: const Icon(Icons.help_outline, size: 14, color: muted)),
          ]),
          const SizedBox(height: 8),
          for (var i = 0; i < site.radar.length; i++)
            _bar(site.axes[i], (site.radar[i] * 100).round(),
                site.live ? null : targets[i]),
          if (site.live && site.visual != null)
            _bar(site.visualReliable ? 'VISUAL' : 'VISUAL (LOW CONFIDENCE)',
                site.visual!.round(), null),
          const SizedBox(height: 14),
          if (!site.live) ...[
            Text('POTENTIAL MISSION USES', style: mono(10, fg)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: const [
              Tag('ROVER TESTING'),
              Tag('GEOLOGICAL FIELDWORK'),
              Tag('ASTROBIOLOGY'),
              Tag('EVA PREP'),
              Tag('ISRU STUDIES'),
            ]),
          ],
          const SizedBox(height: 18),
          Text('Fidelity fingerprint', style: head(24)),
          FidelityRadar(values: site.radar, labels: site.axes, height: 240),
          if (site.live)
            Text('Aridity is left off: it is not defined the same way on another world.',
                style: mono(9)),
          Text('ANALOG FOR WHAT?', style: mono(10, fg)),
          const SizedBox(height: 8),
          for (final u in uses)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Expanded(child: Text(u.$1)),
                SizedBox(
                    width: 34,
                    height: 34,
                    child: Stack(alignment: Alignment.center, children: [
                      CircularProgressIndicator(
                          value: u.$2 / 100,
                          strokeWidth: 3,
                          color: accent,
                          backgroundColor: line),
                      Text('${u.$2}', style: mono(9, accent)),
                    ])),
                SizedBox(width: 44, child: Text('  ${u.$3}', style: mono(9, accent))),
              ]),
            ),
          const SizedBox(height: 14),
          Btn('COMPARE SIDE BY SIDE',
              () => go(
                  c,
                  CompareScreen(
                      site: site,
                      targetName: targetName,
                      targetId: _SelectorTargetIds.of(targetName)))),
          if (site.id.isNotEmpty) ...[
            const SizedBox(height: 10),
            ValueListenableBuilder<List<ShortItem>>(
                valueListenable: Shortlist.items,
                builder: (_, list, __) {
                  final inList = list.any((e) => e.id == site.id);
                  return Btn(
                      inList ? 'IN YOUR SHORTLIST · REMOVE' : 'ADD TO SHORTLIST', () {
                    if (inList) {
                      Shortlist.remove(site.id);
                    } else {
                      Shortlist.add(ShortItem(site.id, site.name, site.meta,
                          _SelectorTargetIds.of(targetName)));
                      final nav = Navigator.of(c);
                      final messenger = ScaffoldMessenger.of(c);
                      messenger.hideCurrentSnackBar();
                      messenger.showSnackBar(SnackBar(
                          duration: const Duration(seconds: 3),
                          persist: false,
                          content: const Text('Added to your shortlist.'),
                          action: SnackBarAction(
                              label: 'VIEW',
                              onPressed: () {
                                messenger.hideCurrentSnackBar();
                                goNav(nav, const ShortlistScreen());
                              })));
                    }
                  }, primary: false);
                }),
          ],
          const SizedBox(height: 24),
        ]),
        back: true);
  }

  Widget _bar(String l, int v, int? t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(children: [
          Row(children: [
            Text(l, style: mono(9)),
            const Spacer(),
            Text(t == null ? 'similarity $v' : '$v · tgt $t', style: mono(9)),
          ]),
          const SizedBox(height: 5),
          LayoutBuilder(
              builder: (_, b) => Stack(children: [
                    Container(height: 5, color: line),
                    Container(height: 5, width: b.maxWidth * v / 100, color: accent),
                    if (t != null)
                      Positioned(
                          left: b.maxWidth * t / 100,
                          child: Container(height: 5, width: 2, color: Colors.white)),
                  ])),
        ]),
      );

  void _showExportSheet(BuildContext c) {
    showModalBottomSheet(
      context: c,
      backgroundColor: card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('EXPORT ${site.name.toUpperCase()}', style: mono(10, fg)),
          const SizedBox(height: 4),
          Text('Copies to your clipboard.', style: mono(9)),
          const SizedBox(height: 14),
          for (final fmt in const [
            ('Text report', 'TXT', Icons.description_outlined),
            ('CSV data', 'CSV', Icons.table_chart_outlined),
            ('JSON', 'JSON', Icons.data_object),
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(fmt.$3, color: accent, size: 20),
              title: Text(fmt.$1, style: const TextStyle(color: fg, fontWeight: FontWeight.w600)),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: _export(fmt.$2)));
                if (sctx.mounted) Navigator.pop(sctx);
                if (c.mounted) {
                  ScaffoldMessenger.of(c).showSnackBar(
                      SnackBar(content: Text('${fmt.$1} copied to clipboard.')));
                }
              },
            ),
        ]),
      ),
    );
  }
}

// ───────────── 6. Trend ("signature moment") ─────────────
class TrendPage extends StatefulWidget {
  final String targetName;
  const TrendPage({super.key, this.targetName = 'Jezero Crater'});
  @override
  State<TrendPage> createState() => _TrendPageState();
}

class _TrendPageState extends State<TrendPage> {
  TrendInfo? _t;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TrendPage old) {
    super.didUpdateWidget(old);
    if (old.targetName != widget.targetName) _load();
  }

  Future<void> _load() async {
    final id = _SelectorTargetIds.of(widget.targetName);
    if (id == null) {
      setState(() {
        _t = null;
        _msg = 'Trends exist for the six standard targets. A custom coordinate has no stored history.';
      });
      return;
    }
    try {
      final t = await BundledAnalysis.trendFor(id);
      if (!mounted) return;
      setState(() {
        _t = t;
        _msg = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _t = null;
        _msg = e is ApiException ? e.message : 'The trend data could not be read.';
      });
    }
  }

  @override
  Widget build(BuildContext c) {
    final t = _t;
    if (t == null) {
      return frame(
          c,
          'TREND',
          _msg == null
              ? const LoadingView()
              : Center(child: Text(_msg!, style: const TextStyle(color: muted))));
    }
    final change = t.similarity.last - t.similarity.first;
    final target = widget.targetName;
    return frame(
        c,
        'TREND',
        ListView(children: [
          Text('${t.siteName.toUpperCase()} · SIMILARITY TO ${target.toUpperCase()}',
              style: mono(9)),
          const SizedBox(height: 10),
          Text(
              t.significant
                  ? (change.abs() < 1
                      ? (t.slopePerYear < 0
                          ? 'A tiny drift\naway'
                          : 'A tiny drift\ncloser')
                      : (t.slopePerYear < 0 ? 'Drifting\naway' : 'Drifting\ncloser'))
                  : 'No measurable\nchange',
              style: head(34)),
          Text('since ${t.years.first}.', style: head(34, accent)),
          const SizedBox(height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)}',
                style: head(52)),
            const SizedBox(width: 10),
            Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('SIMILARITY POINTS\n${t.years.first}–${t.years.last}',
                    style: mono(9, accent))),
          ]),
          const SizedBox(height: 14),
          Panel(
              child: SizedBox(
                  height: 180,
                  child: CustomPaint(
                      size: Size.infinite, painter: LinePainter(t.similarity)))),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('${t.years.first}', style: mono(9)),
            Text('${t.years.last}', style: mono(9)),
          ]),
          const SizedBox(height: 10),
          const Text(
              'The line is drawn on a scale of about ±5 points around the data, so a flat line means a flat result.',
              style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 16),
          Text('THE NUMBERS', style: mono(10, fg)),
          const SizedBox(height: 8),
          for (final r in [
            ('Change per year (Sen slope)', t.slopePerYear.toStringAsFixed(3)),
            ('Mann-Kendall p-value', t.pValue.toStringAsFixed(3)),
            (
              'Verdict',
              t.significant ? 'Statistically significant' : 'Not significant'
            ),
          ])
            Panel(
                child: Row(children: [
              Expanded(child: Text(r.$1)),
              Text(r.$2, style: mono(12, accent)),
            ])),
          const SizedBox(height: 8),
          Text(
              '${t.significantCount} of ${t.total} stored targets show a statistically significant trend'
              '${t.significantAllFalling ? ', and in each of them the similarity falls slightly' : ''}. '
              'These changes are small next to the 0 to 100 scale.',
              style: const TextStyle(color: muted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 8),
          const Text(
              'Only temperature and vegetation vary from year to year in the dataset (2001 to 2024), so this tracks those two for the best-matching site.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 24),
        ]));
  }
}

// ───────────── 7. Reverse mode ─────────────
class ReversePage extends StatefulWidget {
  const ReversePage({super.key});
  @override
  State<ReversePage> createState() => _ReverseState();
}

class _ReverseState extends State<ReversePage>
    with SingleTickerProviderStateMixin {
  final GlobeModel m = GlobeModel();
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  List<ReverseEntry> _cities = const [];
  ReverseEntry? _sel;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadCities();
    _ticker = createTicker((e) {
      final dt = (e - _last).inMicroseconds / 1e6;
      _last = e;
      m.t = e.inMicroseconds / 1e6;
      if (!m.dragging) m.yaw += dt * 0.10; // gentle idle spin
      _tick.value++;
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _tick.dispose();
    super.dispose();
  }

  Future<void> _loadCities() async {
    try {
      final list = await BundledAnalysis.reverseEntries();
      if (!mounted) return;
      setState(() => _cities = list);
      _select(list.first);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError =
          e is ApiException ? e.message : 'The location data could not be read.');
    }
  }

  /// Turns the globe toward a place and shows its stored result.
  void _select(ReverseEntry e) {
    setState(() {
      _sel = e;
      m.selLat = e.lat * math.pi / 180;
      m.selLon = e.lon * math.pi / 180;
      m.yaw = m.selLon;
      m.tilt = (m.selLat * 0.6).clamp(-1.1, 1.1).toDouble();
    });
  }

  /// Great-circle distance in km.
  double _km(double la1, double lo1, double la2, double lo2) {
    final p1 = la1 * math.pi / 180, p2 = la2 * math.pi / 180;
    final dl = (lo2 - lo1) * math.pi / 180, dp = p2 - p1;
    final h = math.pow(math.sin(dp / 2), 2) +
        math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
    return 12742 * math.asin(math.sqrt(h.toDouble().clamp(0.0, 1.0)));
  }

  /// Screen tap → latitude / longitude on the sphere (inverse projection).
  void _pick(Offset pos, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final R = math.min(size.width, size.height) / 2 * kGlobeScale;
    final dx = (pos.dx - c.dx) / R;
    final dy = -(pos.dy - c.dy) / R;
    final d2 = dx * dx + dy * dy;
    if (d2 > 1.0) return; // tapped outside the globe
    final z2 = math.sqrt(1 - d2);
    final ct = math.cos(m.tilt), st = math.sin(m.tilt);
    final y = dy * ct + z2 * st;
    final z = -dy * st + z2 * ct;
    final lat = math.asin(y.clamp(-1.0, 1.0));
    var lon = math.atan2(dx, z) + m.yaw;
    lon = math.atan2(math.sin(lon), math.cos(lon)); // wrap to ±π
    // Only the places in the data have a result: snap to one if it is near.
    ReverseEntry? near;
    var best = 600.0; // km
    final la = lat * 180 / math.pi, lo = lon * 180 / math.pi;
    for (final e in _cities) {
      final dk = _km(la, lo, e.lat, e.lon);
      if (dk < best) {
        best = dk;
        near = e;
      }
    }
    if (near != null) {
      _select(near);
    } else {
      setState(() {
        _sel = null;
        m.selLat = lat;
        m.selLon = lon;
      });
    }
  }

  String _coords() {
    final la = m.selLat * 180 / math.pi, lo = m.selLon * 180 / math.pi;
    return '${la.abs().toStringAsFixed(1)}°${la >= 0 ? 'N' : 'S'}  '
        '${lo.abs().toStringAsFixed(1)}°${lo >= 0 ? 'E' : 'W'}';
  }

  @override
  Widget build(BuildContext c) {
    return frame(
        c,
        'REVERSE MODE',
        backdrop: const _ReverseSpace(),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('How alien is\nyour location?', style: head(30)),
          Text('PICK A PLACE BELOW  ·  DRAG TO SPIN', style: mono(9)),
          const SizedBox(height: 4),
          Text(_coords(), style: mono(9, accent)),
          const SizedBox(height: 4),
          Expanded(
              child: LayoutBuilder(builder: (_, b) {
            final size = Size(b.maxWidth, b.maxHeight);
            final R = math.min(size.width, size.height) / 2 * kGlobeScale;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _pick(d.localPosition, size),
              onPanStart: (_) => m.dragging = true,
              onPanUpdate: (d) {
                m.yaw -= d.delta.dx / R;
                m.tilt = (m.tilt + d.delta.dy / R).clamp(-1.1, 1.1).toDouble();
              },
              onPanEnd: (_) => m.dragging = false,
              onPanCancel: () => m.dragging = false,
              child: CustomPaint(
                size: Size.infinite,
                painter: GlobePainter(m, _tick),
              ),
            );
          })),
          if (_cities.isNotEmpty)
            SizedBox(
                height: 38,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final e in _cities)
                    Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                            onTap: () => _select(e),
                            child: Tag(e.label.toUpperCase(),
                                color: accent, filled: identical(_sel, e)))),
                ])),
          const SizedBox(height: 8),
          _ReversePanel(entry: _sel, error: _loadError),
          const SizedBox(height: 8),
        ]));
  }
}

// ───────────── 3D globe ─────────────
const double kGlobeScale = 0.84;

class GlobeModel {
  double yaw = -0.6; // rotation about the polar axis
  double tilt = 0.38; // pitch toward the viewer
  double t = 0; // seconds, drives pulses
  double selLat = 0.31, selLon = 0.63; // selected point (radians)
  bool dragging = false;
}

class _V {
  final double x, y, z;
  const _V(this.x, this.y, this.z);
}

/// Densified (radians) copies of the outlines so edges curve with the sphere.
/// `landRaw` (flat lon,lat degree pairs) comes from land_data.dart.
final List<List<List<double>>> _land = landRaw.map((raw) {
  final lons = <double>[], lats = <double>[];
  final n = raw.length ~/ 2;
  for (var i = 0; i < n; i++) {
    final j = (i + 1) % n;
    final lo0 = raw[i * 2], la0 = raw[i * 2 + 1];
    final lo1 = raw[j * 2], la1 = raw[j * 2 + 1];
    final steps = math.max(1, (math.max((lo1 - lo0).abs(), (la1 - la0).abs()) / 4).ceil());
    for (var k = 0; k < steps; k++) {
      final f = k / steps;
      lons.add((lo0 + (lo1 - lo0) * f) * math.pi / 180);
      lats.add((la0 + (la1 - la0) * f) * math.pi / 180);
    }
  }
  return [lons, lats];
}).toList();

/// Dark globe, flat grey continents, orange city lights, glowing orange rim.
class GlobePainter extends CustomPainter {
  final GlobeModel m;
  GlobePainter(this.m, Listenable repaint) : super(repaint: repaint);

  static const _orange = Color(0xFFFF7A1F);
  static const _hot = Color(0xFFFFB066);

  _V _proj(double lat, double lon, double k) {
    final cl = math.cos(lat);
    final lr = lon - m.yaw;
    final x = cl * math.sin(lr), y = math.sin(lat), z = cl * math.cos(lr);
    final ct = math.cos(m.tilt), st = math.sin(m.tilt);
    return _V(x * k, (y * ct - z * st) * k, (y * st + z * ct) * k);
  }

  @override
  void paint(Canvas cv, Size s) {
    final c = s.center(Offset.zero);
    final R = math.min(s.width, s.height) / 2 * kGlobeScale;
    final globe = Rect.fromCircle(center: c, radius: R);
    final pulse = 0.5 + 0.5 * math.sin(m.t * 1.6);
    Offset sp(_V v) => Offset(c.dx + v.x * R, c.dy - v.y * R);
    // Back-facing points are pushed to the limb so polygons stay closed.
    Offset spc(_V v) {
      if (v.z >= 0) return sp(v);
      final n = math.sqrt(v.x * v.x + v.y * v.y);
      if (n < 1e-6) return c;
      return Offset(c.dx + v.x / n * R, c.dy - v.y / n * R);
    }

    // ── Tight orange halo hugging the globe ──
    cv.drawCircle(
        c,
        R * 1.02,
        Paint()
          ..color = _orange.withAlpha((30 + 18 * pulse).round())
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, R * 0.07));

    // ── Dark ocean sphere ──
    cv.drawCircle(
        c,
        R,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-.4, -.45),
            radius: 1.1,
            colors: [Color(0xFF17171C), Color(0xFF0A0A0D), Color(0xFF030304)],
            stops: [0, .55, 1],
          ).createShader(globe));

    cv.save();
    cv.clipPath(Path()..addOval(globe));

    // ── Graticule ──
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = _orange.withAlpha(48);
    for (var latD = -60; latD <= 60; latD += 30) {
      final p = Path();
      var pen = false;
      for (var lonD = -180; lonD <= 180; lonD += 6) {
        final v = _proj(latD * math.pi / 180, lonD * math.pi / 180, 1.0);
        if (v.z > 0) {
          final o = sp(v);
          pen ? p.lineTo(o.dx, o.dy) : p.moveTo(o.dx, o.dy);
          pen = true;
        } else {
          pen = false;
        }
      }
      cv.drawPath(p, grid);
    }
    for (var lonD = -180; lonD < 180; lonD += 30) {
      final p = Path();
      var pen = false;
      for (var latD = -90; latD <= 90; latD += 5) {
        final v = _proj(latD * math.pi / 180, lonD * math.pi / 180, 1.0);
        if (v.z > 0) {
          final o = sp(v);
          pen ? p.lineTo(o.dx, o.dy) : p.moveTo(o.dx, o.dy);
          pen = true;
        } else {
          pen = false;
        }
      }
      cv.drawPath(p, grid);
    }

    // ── Dark-grey continents with a glowing orange coastline outline ──
    final landFill = Paint()
      ..shader = ui.Gradient.linear(
        c + Offset(-R * 0.7, -R * 0.7),
        c + Offset(R * 0.7, R * 0.7),
        const [Color(0xFF5A5A62), Color(0xFF1C1C21)],
      );
    final coast = Path();
    for (final poly in _land) {
      final lons = poly[0], lats = poly[1];
      final n = lons.length;
      final base = List<_V>.generate(n, (i) => _proj(lats[i], lons[i], 1.0));
      if (!base.any((v) => v.z > 0)) continue;
      cv.drawPath(Path()..addPolygon(base.map(spc).toList(), true), landFill);
      var pen = false;
      for (var i = 0; i <= n; i++) {
        final v = base[i % n];
        if (v.z > 0.05) {
          final o = sp(v);
          pen ? coast.lineTo(o.dx, o.dy) : coast.moveTo(o.dx, o.dy);
          pen = true;
        } else {
          pen = false;
        }
      }
    }
    // soft orange glow under the coastline
    cv.drawPath(
        coast,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.2
          ..strokeJoin = StrokeJoin.round
          ..color = _orange.withAlpha(110)
          ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 2.5));
    // crisp orange coastline
    cv.drawPath(
        coast,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9
          ..strokeJoin = StrokeJoin.round
          ..color = _hot.withAlpha(215));

    // ── Orange city lights ──
    final glowPts = <Offset>[], dotPts = <Offset>[];
    for (final p in _cityLights) {
      final v = _proj(p[0], p[1], 1.0);
      if (v.z < 0.06) continue;
      final o = sp(v);
      dotPts.add(o);
      if (p[2] > 0.6) glowPts.add(o);
    }
    cv.drawPoints(
        ui.PointMode.points,
        glowPts,
        Paint()
          ..strokeWidth = 4.5
          ..strokeCap = StrokeCap.round
          ..color = _orange.withAlpha(46));
    cv.drawPoints(
        ui.PointMode.points,
        dotPts,
        Paint()
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round
          ..color = _hot.withAlpha(215));

    // ── Limb darkening + faint orange edge light inside the rim ──
    cv.drawCircle(
        c,
        R,
        Paint()
          ..shader = RadialGradient(
            colors: [Colors.transparent, Colors.black.withAlpha(120)],
            stops: const [0.72, 1],
          ).createShader(globe));
    cv.drawCircle(
        c,
        R,
        Paint()
          ..shader = RadialGradient(
            colors: [Colors.transparent, _orange.withAlpha(120)],
            stops: const [0.90, 1],
          ).createShader(globe));
    cv.restore();

    // ── Fiery orange rim: thin bright line, brighter on the left / lower-left
    // and top, with a soft glow just outside it ──
    final rimGlow = const SweepGradient(
      colors: [
        Color(0xC8FF7A1F),
        Color(0xEBFF7A1F),
        Color(0xFFFF8A2A),
        Color(0xE6FF7A1F),
        Color(0xC8FF7A1F),
      ],
      stops: [0.0, 0.25, 0.5, 0.75, 1.0],
    ).createShader(globe);
    final rimLine = const SweepGradient(
      colors: [
        Color(0xBEFF9A4D),
        Color(0xE6FFA85C),
        Color(0xFFFFB066),
        Color(0xE6FFA85C),
        Color(0xBEFF9A4D),
      ],
      stops: [0.0, 0.25, 0.5, 0.75, 1.0],
    ).createShader(globe);
    // wide faint bloom
    cv.drawCircle(
        c,
        R * 1.01,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = R * 0.09
          ..color = _orange.withAlpha((45 + 25 * pulse).round())
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, R * 0.07));
    // tight glow
    cv.drawCircle(
        c,
        R,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = R * 0.04
          ..shader = rimGlow
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, R * 0.025));
    // crisp outline
    cv.drawCircle(
        c,
        R,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..shader = rimLine);

    // ── Selected location: pulsing rings + beacon ──
    final v = _proj(m.selLat, m.selLon, 1.0);
    if (v.z > 0.03) {
      var e1x = v.z, e1y = 0.0, e1z = -v.x;
      var l1 = math.sqrt(e1x * e1x + e1z * e1z);
      if (l1 < 1e-3) {
        e1x = 1;
        e1z = 0;
        l1 = 1;
      }
      e1x /= l1;
      e1z /= l1;
      final e2x = v.y * e1z - v.z * e1y;
      final e2y = v.z * e1x - v.x * e1z;
      final e2z = v.x * e1y - v.y * e1x;
      for (var i = 0; i < 3; i++) {
        final ph = (m.t * 0.7 + i / 3) % 1.0;
        final rho = 0.03 + 0.2 * ph;
        final ring = Path();
        for (var k = 0; k <= 36; k++) {
          final a = k / 36 * 2 * math.pi;
          final ca = math.cos(a) * rho, sa = math.sin(a) * rho;
          var px = v.x + ca * e1x + sa * e2x;
          var py = v.y + ca * e1y + sa * e2y;
          var pz = v.z + ca * e1z + sa * e2z;
          final nn = math.sqrt(px * px + py * py + pz * pz);
          px /= nn;
          py /= nn;
          pz /= nn;
          final o = Offset(c.dx + px * R, c.dy - py * R);
          k == 0 ? ring.moveTo(o.dx, o.dy) : ring.lineTo(o.dx, o.dy);
        }
        cv.drawPath(
            ring,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6
              ..color = _orange.withAlpha((210 * (1 - ph)).round()));
      }
      final top = _proj(m.selLat, m.selLon, 1.12);
      final p0 = sp(v), p1 = sp(top);
      cv.drawLine(
          p0,
          p1,
          Paint()
            ..strokeWidth = 1.4
            ..shader = ui.Gradient.linear(p0, p1, [_orange.withAlpha(120), _hot]));
      cv.drawCircle(
          p0,
          9 + 3 * pulse,
          Paint()
            ..color = _orange.withAlpha(150)
            ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 6));
      cv.drawCircle(p0, 3.6, Paint()..color = const Color(0xFFFFE0C4));
      cv.drawCircle(p1, 2.2, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant GlobePainter old) => true;
}

/// Point-in-polygon test against the coarse continent outlines (lon/lat deg).
bool _inLand(double lon, double lat) {
  for (final raw in landRaw) {
    final n = raw.length ~/ 2;
    var inside = false;
    for (var i = 0, j = n - 1; i < n; j = i++) {
      final xi = raw[i * 2], yi = raw[i * 2 + 1];
      final xj = raw[j * 2], yj = raw[j * 2 + 1];
      if ((yi > lat) != (yj > lat) &&
          lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    if (inside) return true;
  }
  return false;
}

/// City-light dots: [lat rad, lon rad, brightness 0..1], clustered around
/// population hubs and kept on land.
final List<List<double>> _cityLights = () {
  final r = math.Random(3);
  double gauss() =>
      math.sqrt(-2 * math.log(1 - r.nextDouble())) * math.cos(2 * math.pi * r.nextDouble());
  // lon, lat, spread (deg), count
  const hubs = <List<double>>[
    [10, 49, 7, 170], // Europe
    [38, 56, 5, 45], // W. Russia
    [35, 32, 6, 60], // Levant / Middle East
    [31, 28, 2.5, 35], // Nile
    [3, 7, 4, 35], // W. Africa
    [37, 0, 3, 15], // E. Africa
    [28, -27, 3, 25], // S. Africa
    [78, 22, 6, 110], // India
    [114, 31, 6, 110], // E. China
    [105, 14, 5, 50], // SE Asia
    [110, -7, 3, 40], // Java
    [137, 35, 2.5, 40], // Japan
    [150, -33, 3, 20], // E. Australia
    [-77, 39, 5, 80], // E. USA
    [-88, 41, 4, 40], // Great Lakes
    [-120, 36, 3, 25], // California
    [-99, 19, 3, 25], // Mexico
    [-46, -23, 4, 45], // Brazil
    [-60, -34, 3, 20], // Argentina
  ];
  final out = <List<double>>[];
  void add(double lon, double lat, double b) =>
      out.add([lat * math.pi / 180, lon * math.pi / 180, b]);
  for (final h in hubs) {
    final count = h[3].round();
    var added = 0, tries = 0;
    while (added < count && tries < count * 8) {
      tries++;
      final lon = h[0] + gauss() * h[2];
      final lat = h[1] + gauss() * h[2] * 0.8;
      if (!_inLand(lon, lat)) continue;
      add(lon, lat, 0.3 + 0.7 * r.nextDouble());
      added++;
    }
  }
  // faint scattered lights everywhere else on land
  var added = 0, tries = 0;
  while (added < 220 && tries < 4000) {
    tries++;
    final lon = -170 + r.nextDouble() * 340;
    final lat = -50 + r.nextDouble() * 120;
    if (!_inLand(lon, lat)) continue;
    add(lon, lat, 0.1 + 0.4 * r.nextDouble());
    added++;
  }
  return out;
}();

/// Near-black sky with sparse orange / white stars and thin 4-point sparkles
/// (Reverse Mode only).
class _ReverseSpace extends StatefulWidget {
  const _ReverseSpace();
  @override
  State<_ReverseSpace> createState() => _ReverseSpaceState();
}

class _ReverseSpaceState extends State<_ReverseSpace>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  // x, y, size, phase, speed, sparkle(1/0), orange(1/0)
  static final List<List<double>> _s = () {
    final r = math.Random(42);
    return List.generate(95, (i) {
      final sparkle = i < 16;
      return [
        r.nextDouble(),
        r.nextDouble(),
        sparkle ? 1.0 + r.nextDouble() * 0.6 : 0.5 + r.nextDouble() * 0.7,
        r.nextDouble() * 6.283,
        0.5 + r.nextDouble() * 1.6,
        sparkle ? 1.0 : 0.0,
        r.nextDouble() < 0.55 ? 1.0 : 0.0,
      ];
    });
  }();

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 3600))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
      child: RepaintBoundary(
          child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) => CustomPaint(
                  size: Size.infinite,
                  painter: _ReverseSpacePainter(_s, _c.value * 3600)))));
}

class _ReverseSpacePainter extends CustomPainter {
  final List<List<double>> stars;
  final double t;
  _ReverseSpacePainter(this.stars, this.t);

  @override
  void paint(Canvas cv, Size s) {
    cv.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF020203));
    for (final st in stars) {
      final tw = 0.5 + 0.5 * math.sin(t * st[4] + st[3]);
      final o = Offset(st[0] * s.width, st[1] * s.height);
      final col = st[6] > 0.5 ? const Color(0xFFFF8A3D) : Colors.white;
      cv.drawCircle(o, st[2], Paint()..color = col.withAlpha((90 + 130 * tw).round()));
    }
  }

  @override
  bool shouldRepaint(covariant _ReverseSpacePainter old) => old.t != t;
}

/// Flat, transparent "YOUR LOCATION" panel with thin orange outlines
/// (Reverse Mode only).
class _ReversePanel extends StatelessWidget {
  final ReverseEntry? entry;
  final String? error;
  const _ReversePanel({this.entry, this.error});

  Widget _card(String l, String name, double score, double pct) => Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
          color: const Color(0xFF0A0605),
          border: Border.all(color: accent.withAlpha(120), width: 1),
          borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l, style: mono(9, accent)),
        const SizedBox(height: 6),
        Text('${pct.round()}%', style: head(28)),
        Text('more than this share of the 600 Earth sites',
            style: const TextStyle(color: muted, fontSize: 10, height: 1.3)),
        const SizedBox(height: 6),
        Text('$name · ${score.toStringAsFixed(1)} / 100',
            style: mono(9, fg)),
      ]));

  @override
  Widget build(BuildContext c) {
    final e = entry;
    return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
        decoration: BoxDecoration(
            color: const Color(0xFF050404),
            border: Border.all(color: accent.withAlpha(100), width: 1),
            borderRadius: BorderRadius.circular(22)),
        child: error != null
            ? Text(error!, style: const TextStyle(color: muted))
            : e == null
                ? const Text(
                    'No result for this spot. Only the places in the list have stored results. Pick one of them.',
                    style: TextStyle(color: muted, height: 1.4))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${e.label.toUpperCase()} · ${e.verdict.toUpperCase()}',
                        style: mono(9)),
                    const SizedBox(height: 12),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                          child: _card('MARS-LIKE', e.marsName, e.marsScore, e.marsPct)),
                      const SizedBox(width: 10),
                      Expanded(
                          child: _card('MOON-LIKE', e.moonName, e.moonScore, e.moonPct)),
                    ]),
                    const SizedBox(height: 10),
                    Text(e.note,
                        style: const TextStyle(color: muted, fontSize: 11, height: 1.4)),
                  ]));
  }
}

// ───────────── Glowing brand logo ─────────────
/// Nav-bar logo: bigger, with a pulsing warm halo and a periodic shine sweep
/// so the brand reads clearly from a distance.
class GlowLogo extends StatefulWidget {
  final double height;
  const GlowLogo({super.key, this.height = 48});
  @override
  State<GlowLogo> createState() => _GlowLogoState();
}

class _GlowLogoState extends State<GlowLogo> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    final rad = BorderRadius.circular(h * 0.22);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final pulse = 0.5 + 0.5 * math.sin(_c.value * 2 * math.pi);
        return Container(
          decoration: BoxDecoration(borderRadius: rad, boxShadow: [
            BoxShadow(
                color: accent.withAlpha((80 + 100 * pulse).round()),
                blurRadius: 14 + 12 * pulse,
                spreadRadius: 1 + 2 * pulse),
            BoxShadow(
                color: const Color(0xFFFFD2A8).withAlpha((40 + 60 * pulse).round()),
                blurRadius: 6),
          ]),
          foregroundDecoration: BoxDecoration(
              borderRadius: rad,
              border: Border.all(
                  color: const Color(0xFFFFC9A0).withAlpha((90 + 110 * pulse).round()),
                  width: 1.2)),
          child: ClipRRect(
            borderRadius: rad,
            child: Stack(children: [
              Image.asset('assets/geox_logo.png',
                  height: h,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, __, ___) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text('GEOX', style: head(22, accent)))),
              Positioned.fill(
                  child: IgnorePointer(child: CustomPaint(painter: _ShimmerPainter(_c.value)))),
            ]),
          ),
        );
      },
    );
  }
}

class _ShimmerPainter extends CustomPainter {
  final double t;
  _ShimmerPainter(this.t);
  @override
  void paint(Canvas cv, Size s) {
    const active = 0.45; // sweep during the first 45% of each cycle
    if (t > active) return;
    final u = Curves.easeInOut.transform(t / active);
    final bw = s.width * 0.55;
    final left = -bw + (s.width + bw) * u;
    final rect = Rect.fromLTWH(left, 0, bw, s.height);
    cv.save();
    cv.translate(left + bw / 2, s.height / 2);
    cv.transform(Matrix4.skewX(-0.35).storage);
    cv.translate(-(left + bw / 2), -s.height / 2);
    cv.drawRect(
        rect,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.linear(rect.centerLeft, rect.centerRight, [
            Colors.white.withAlpha(0),
            Colors.white.withAlpha(150),
            Colors.white.withAlpha(0),
          ], const [
            0,
            .5,
            1
          ]));
    cv.restore();
  }

  @override
  bool shouldRepaint(covariant _ShimmerPainter old) => old.t != t;
}

// ───────────── 8. Priorities ─────────────
class PrioritiesScreen extends StatefulWidget {
  const PrioritiesScreen({super.key});
  @override
  State<PrioritiesScreen> createState() => _PrioritiesState();
}

class _PrioritiesState extends State<PrioritiesScreen> {
  int preset = SavedPriorities.preset;
  final List<double> w = List<double>.of(SavedPriorities.weights);
  bool _dirty = false;

  void _save() {
    SavedPriorities.preset = preset;
    SavedPriorities.weights = List<double>.of(w);
    SavedPriorities.hasSaved = true;
    SavedPriorities.persist();
    SavedPriorities.version.value++;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Saved: ${presets[preset]}. Open the results to see the new order.')));
  }

  static const presets = ['ROVER MOBILITY', 'GEOLOGY', 'ASTROBIOLOGY', 'EVA', 'ISRU'];

  /// Each mission mapped onto the five fingerprint axes
  /// (terrain, thermal, aridity, vegetation, bare ground). An approximate
  /// reading of what each kind of mission cares about.
  static const presetWeights = <List<double>>[
    [1.0, 0.0, 0.0, 0.0, 0.0],
    [0.4, 0.0, 0.0, 0.0, 0.6],
    [0.0, 0.34, 0.33, 0.33, 0.0],
    [0.35, 0.65, 0.0, 0.0, 0.0],
    [0.0, 0.33, 0.33, 0.0, 0.34],
  ];
  @override
  Widget build(BuildContext c) => frame(
      c,
      'MISSION PRIORITIES',
      ListView(children: [
        Text('TUNE THE MATCH', style: mono(9)),
        const SizedBox(height: 6),
        Text('What matters\nmost?', style: head(30)),
        const SizedBox(height: 14),
        Text('MISSION PRESET', style: mono(9)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < presets.length; i++)
            GestureDetector(
                onTap: () => setState(() {
                  preset = i;
                  w.setAll(0, presetWeights[i]);
                  _dirty = true;
                }),
                child: Tag(presets[i], color: accent, filled: preset == i)),
        ]),
        const SizedBox(height: 16),
        Text('WEIGHTS', style: mono(9)),
        for (var i = 0; i < 5; i++)
          Row(children: [
            SizedBox(width: 70, child: Text(labels[i], style: mono(9))),
            Expanded(
                child: Slider(
                    value: w[i],
                    activeColor: accent,
                    inactiveColor: line,
                    onChanged: (v) => setState(() {
                      w[i] = v;
                      _dirty = true;
                    }))),
            Text(w[i].toStringAsFixed(2), style: mono(10, accent)),
          ]),
        Panel(
            child: Text(
                'Saving re-orders the results you are looking at, using these weights on the five fingerprint scores. It covers the results shown (up to 25), not all 600 sites. The satellite score is not part of this. Where a result has no aridity score, that weight is ignored.',
                style: const TextStyle(color: muted, fontSize: 12, height: 1.4))),
        const SizedBox(height: 14),
        Row(children: [
          Icon(
              _dirty
                  ? Icons.edit_outlined
                  : (SavedPriorities.hasSaved
                      ? Icons.check_circle_outline
                      : Icons.info_outline),
              size: 14,
              color: _dirty ? _warn : (SavedPriorities.hasSaved ? teal : muted)),
          const SizedBox(width: 6),
          Expanded(
              child: Text(
                  _dirty
                      ? 'UNSAVED CHANGES'
                      : (SavedPriorities.hasSaved
                          ? 'SAVED · ${presets[SavedPriorities.preset]}'
                          : 'NOT SAVED YET'),
                  style: mono(9, _dirty ? _warn : muted))),
        ]),
        const SizedBox(height: 10),
        Btn('SAVE PRIORITIES', _save),
        const SizedBox(height: 24),
      ]),
      back: true);
}

// ───────────── Shortlist ─────────────
class ShortItem {
  final String id, name, meta;

  /// The standard target it was found for (mars_jezero ...), when there is one.
  final String? targetId;
  const ShortItem(this.id, this.name, this.meta, this.targetId);
}

/// The sites the person picked. Saved on this device so it survives a restart.
class Shortlist {
  static const _key = 'geox_shortlist';
  static final ValueNotifier<List<ShortItem>> items =
      ValueNotifier<List<ShortItem>>(const []);

  static void add(ShortItem e) {
    if (items.value.any((x) => x.id == e.id)) return;
    items.value = [...items.value, e];
    _save();
  }

  static void remove(String id) {
    items.value = [for (final x in items.value) if (x.id != id) x];
    _save();
  }

  /// Reads the saved list. If anything is wrong the list simply starts empty.
  static Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final list = jsonDecode(raw) as List<dynamic>;
      items.value = [
        for (final m in list)
          if (m is Map && m['id'] is String)
            ShortItem(m['id'] as String, (m['name'] ?? '').toString(),
                (m['meta'] ?? '').toString(), m['targetId'] as String?)
      ];
      debugPrint('Shortlist: loaded ${items.value.length} saved item(s)');
    } catch (e) {
      debugPrint('Shortlist: could not load: $e');
    }
  }

  static Future<void> _save() async {
    try {
      final data = [
        for (final e in items.value)
          {'id': e.id, 'name': e.name, 'meta': e.meta, 'targetId': e.targetId}
      ];
      final ok = await (await SharedPreferences.getInstance())
          .setString(_key, jsonEncode(data));
      debugPrint('Shortlist: saved ${data.length} item(s), ok=$ok');
    } catch (e) {
      debugPrint('Shortlist: could not save: $e');
    }
  }
}

class ShortlistScreen extends StatefulWidget {
  const ShortlistScreen({super.key});
  @override
  State<ShortlistScreen> createState() => _ShortlistState();
}

class _ShortlistState extends State<ShortlistScreen> {
  final _code = TextEditingController();
  String? _sharedCode, _error;
  SharedList? _opened;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    final list = Shortlist.items.value;
    if (list.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await GeoXApi.createShortlist(
          ids: [for (final e in list) e.id],
          targetId: list.map((e) => e.targetId).whereType<String>().firstOrNull);
      if (!mounted) return;
      setState(() => _sharedCode = code);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          e is ApiException ? e.message : 'Could not share the shortlist.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openCode() async {
    final code = _code.text.trim();
    if (code.isEmpty || _busy) {
      setState(() => _error = 'Type a share code first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _opened = null;
    });
    try {
      final r = await GeoXApi.readShortlist(code);
      if (!mounted) return;
      setState(() => _opened = r);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          e is ApiException ? e.message : 'Could not open that shortlist.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _addAll(SharedList l) {
    for (final x in l.sites.where((x) => !x.missing)) {
      Shortlist.add(ShortItem(
          x.id,
          x.name ?? x.id,
          x.lat != null && x.lon != null ? fmtCoords(x.lat!, x.lon!) : '',
          l.targetId));
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
          duration: Duration(seconds: 3),
          content: Text('Added to your shortlist.')));
  }

  @override
  Widget build(BuildContext c) => frame(
      c,
      'SHORTLIST',
      ListView(children: [
        Text('YOUR PICKS', style: mono(9)),
        const SizedBox(height: 6),
        Text('Your\nshortlist', style: head(30)),
        const SizedBox(height: 14),
        ValueListenableBuilder<List<ShortItem>>(
            valueListenable: Shortlist.items,
            builder: (_, list, __) => list.isEmpty
                ? const Panel(
                    child: Text(
                        'Nothing here yet. Open a site and press ADD TO SHORTLIST.',
                        style: TextStyle(color: muted, height: 1.4)))
                : Column(children: [
                    for (final e in list)
                      Panel(
                          child: Row(children: [
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(e.name,
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                              if (e.meta.isNotEmpty) Text(e.meta, style: mono(9)),
                            ])),
                        IconButton(
                            icon: const Icon(Icons.close, size: 18, color: muted),
                            onPressed: () => Shortlist.remove(e.id)),
                      ])),
                    const SizedBox(height: 6),
                    Btn(_busy ? 'WORKING…' : 'SHARE SHORTLIST', _share),
                  ])),
        if (_sharedCode != null) ...[
          const SizedBox(height: 10),
          Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('SHARE CODE', style: mono(9, accent)),
            const SizedBox(height: 6),
            Text(_sharedCode!, style: head(28)),
            const SizedBox(height: 6),
            const Text(
                'Anyone using GeoX with access to the same server can open this list with the code.',
                style: TextStyle(color: muted, fontSize: 12, height: 1.4)),
            const SizedBox(height: 8),
            GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _sharedCode!));
                  ScaffoldMessenger.of(c).showSnackBar(
                      const SnackBar(content: Text('Code copied.')));
                },
                child: Text('COPY CODE', style: mono(10, teal))),
          ])),
        ],
        const SizedBox(height: 22),
        Text('OPEN A SHARED SHORTLIST', style: mono(9)),
        const SizedBox(height: 8),
        _authField(
            ctrl: _code,
            label: 'Share code',
            icon: Icons.tag,
            action: TextInputAction.done),
        const SizedBox(height: 10),
        Btn('OPEN', _openCode, primary: false),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(color: _warn, fontSize: 12)),
        ],
        if (_opened != null) ...[
          const SizedBox(height: 14),
          Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('SHARED LIST · ${_opened!.code}', style: mono(9, accent)),
            const SizedBox(height: 8),
            for (final x in _opened!.sites)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(
                        child: Text(x.missing ? '${x.id} (not in this dataset)' : (x.name ?? x.id))),
                    if (x.lat != null && x.lon != null)
                      Text(fmtCoords(x.lat!, x.lon!), style: mono(9)),
                  ])),
          ])),
          const SizedBox(height: 10),
          Btn('ADD ALL TO MY SHORTLIST', () => _addAll(_opened!), primary: false),
        ],
        const SizedBox(height: 24),
      ]),
      back: true);
}

// ───────────── 9. Compare ─────────────
/// The satellite picture of a standard target, with a plain caption.
class _TargetPicture extends StatefulWidget {
  final String targetId;
  final bool isMoon;
  const _TargetPicture({required this.targetId, required this.isMoon});
  @override
  State<_TargetPicture> createState() => _TargetPictureState();
}

class _TargetPictureState extends State<_TargetPicture> {
  TargetInfo? _info;

  @override
  void initState() {
    super.initState();
    BundledTargets.targetInfo(widget.targetId).then((v) {
      if (mounted) setState(() => _info = v);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext c) {
    final src = _info?.tileSource ?? '';
    final scale = RegExp(r'(\d+) m/px').firstMatch(src)?.group(1);
    final unlit = src.contains('genuinely unlit');
    final caption = [
      'NASA TREK IMAGE',
      if (scale != null) '$scale M/PX',
      if (unlit) 'NO SUNLIGHT REACHES HERE',
    ].join(' · ');
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 220,
        width: double.infinity,
        child: Stack(fit: StackFit.expand, children: [
          Image.asset('assets/target_tiles/${widget.targetId}.jpg',
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                  color: widget.isMoon
                      ? const Color(0xFF3A3D43)
                      : const Color(0xFF6E3A20),
                  alignment: Alignment.bottomLeft,
                  padding: const EdgeInsets.all(10),
                  child: Text('PICTURE NOT AVAILABLE',
                      style: mono(9, Colors.white70)))),
          Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(caption, style: mono(9, Colors.white)))),
        ]),
      ),
    );
  }
}

/// Earth site and target side by side, with the measured values underneath.
class _TileCompare extends StatefulWidget {
  final Site site;
  final String targetId, targetName;
  const _TileCompare(
      {required this.site, required this.targetId, required this.targetName});
  @override
  State<_TileCompare> createState() => _TileCompareState();
}

class _TileCompareState extends State<_TileCompare> {
  double split = .5;
  TargetInfo? _target;
  Map<String, double> _earth = const {};

  @override
  void initState() {
    super.initState();
    BundledTargets.targetInfo(widget.targetId).then((v) {
      if (mounted) setState(() => _target = v);
    }).catchError((_) {});
    BundledTargets.siteFeatures(widget.site.id).then((v) {
      if (mounted) setState(() => _earth = v);
    }).catchError((_) {});
  }

  static String _fmt(String k, double v) {
    switch (k) {
      case 'slope':
        return v.toStringAsFixed(1);
      case 'roughness':
        return v.toStringAsFixed(0);
      case 'temperature':
      case 'temperature_variation':
        return '${v.toStringAsFixed(0)} °C';
      case 'ndvi':
        return v.toStringAsFixed(2);
      default:
        return '${(v * 100).round()}%';
    }
  }

  @override
  Widget build(BuildContext c) {
    final t = _target;
    final unlit = (t?.tileSource ?? '').contains('genuinely unlit');
    const rows = <(String, String)>[
      ('Slope', 'slope'),
      ('Roughness', 'roughness'),
      ('Surface temperature', 'temperature'),
      ('Day to night swing', 'temperature_variation'),
      ('Vegetation (NDVI)', 'ndvi'),
      ('Bare ground', 'bare_ground'),
    ];
    Widget img(String path) => Image.asset(path,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => Container(
            color: const Color(0xFF1B2333),
            alignment: Alignment.center,
            child: Text('PICTURE NOT AVAILABLE', style: mono(9, Colors.white70))));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      LayoutBuilder(
        builder: (_, b) => GestureDetector(
          onHorizontalDragUpdate: (d) => setState(() =>
              split = (split + d.delta.dx / b.maxWidth).clamp(.05, .95)),
          child: SizedBox(
            height: 220,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(children: [
                Positioned.fill(child: img('assets/earth_tiles/${widget.site.id}.jpg')),
                Positioned(
                    left: b.maxWidth * split,
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: ClipRect(
                        child: OverflowBox(
                            alignment: Alignment.centerRight,
                            minWidth: b.maxWidth,
                            maxWidth: b.maxWidth,
                            child: img('assets/target_tiles/${widget.targetId}.jpg')))),
                Positioned(
                    left: b.maxWidth * split - 1,
                    top: 0,
                    bottom: 0,
                    child: Container(width: 2, color: Colors.white)),
                Positioned(
                    left: b.maxWidth * split - 14,
                    top: 96,
                    child: const CircleAvatar(
                        radius: 14,
                        backgroundColor: Colors.black,
                        child: Icon(Icons.code, size: 16))),
                Positioned(
                    left: 0,
                    bottom: 0,
                    child: Container(
                        color: Colors.black54,
                        padding: const EdgeInsets.all(6),
                        child: Text('EARTH · ${widget.site.name.toUpperCase()}',
                            style: mono(9, Colors.white)))),
                Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                        color: Colors.black54,
                        padding: const EdgeInsets.all(6),
                        child: Text(widget.targetName.toUpperCase(),
                            style: mono(9, Colors.white)))),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
          unlit
              ? 'This target is permanently shadowed, so its picture is black. It was scored on the measured values below, not on how the pictures look.'
              : 'Drag the divider. The Earth picture is sharper than the planetary one, so the two are not the same detail level.',
          style: const TextStyle(color: muted, fontSize: 11, height: 1.4)),
      const SizedBox(height: 14),
      Text('MEASURED VALUES', style: mono(10, fg)),
      const SizedBox(height: 4),
      for (final r in rows)
        if (_earth[r.$2] != null && t?.features[r.$2] != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Text(r.$1, style: mono(10)),
                const Spacer(),
                Text('${_fmt(r.$2, _earth[r.$2]!)}  →  ${_fmt(r.$2, t!.features[r.$2]!)}',
                    style: mono(11, fg)),
              ])),
      Text('Earth site  →  ${widget.targetName}',
          style: const TextStyle(color: muted, fontSize: 11)),
      const SizedBox(height: 8),
    ]);
  }
}

class CompareScreen extends StatefulWidget {
  final Site site;
  final String targetName;

  /// The standard target being compared against (mars_jezero ...), when there is one.
  final String? targetId;
  const CompareScreen(
      {super.key,
      required this.site,
      this.targetName = 'Jezero Crater',
      this.targetId});
  @override
  State<CompareScreen> createState() => _CompareState();
}

class _CompareState extends State<CompareScreen> {
  double split = .5;

  /// True when this site came from the bundled data and its pictures are in the app.
  bool get _tiles =>
      widget.site.source == 'bundle' &&
      widget.site.id.isNotEmpty &&
      widget.targetId != null;

  @override
  Widget build(BuildContext c) => frame(
      c,
      'COMPARE',
      ListView(children: [
        if (_tiles)
          _TileCompare(
              site: widget.site,
              targetId: widget.targetId!,
              targetName: widget.targetName)
        else if (widget.site.live)
          Panel(
              child: Text(
                  widget.site.source == 'bundle'
                      ? 'The side-by-side imagery is not bundled with this build yet. The environment and visual similarity scores are on the site page.'
                      : 'No satellite picture exists for a point you chose, so the side-by-side imagery and the per-feature values are not shown. The similarity scores are on the site page.',
                  style: const TextStyle(color: muted, height: 1.4)))
        else if (kPreviewData)
          const _PreviewNote(),
        if (!widget.site.live)
          LayoutBuilder(
            builder: (_, b) => GestureDetector(
                  onHorizontalDragUpdate: (d) => setState(() =>
                      split = (split + d.delta.dx / b.maxWidth).clamp(.05, .95)),
                  child: SizedBox(
                    height: 200,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Stack(children: [
                        Positioned.fill(
                            child: Container(
                                color: const Color(0xFF8A7A3A),
                                alignment: Alignment.bottomLeft,
                                padding: const EdgeInsets.all(10),
                                child: Text('EARTH · ${widget.site.name.toUpperCase()}',
                                    style: mono(9, Colors.white)))),
                        Positioned(
                            left: b.maxWidth * split,
                            right: 0,
                            top: 0,
                            bottom: 0,
                            child: Container(
                                color: const Color(0xFFB5501F),
                                alignment: Alignment.bottomRight,
                                padding: const EdgeInsets.all(10),
                                child: Text(widget.targetName.toUpperCase(),
                                    style: mono(9, Colors.white)))),
                        Positioned(
                            left: b.maxWidth * split - 14,
                            top: 86,
                            child: const CircleAvatar(
                                radius: 14,
                                backgroundColor: Colors.black,
                                child: Icon(Icons.code, size: 16))),
                      ]),
                    ),
                  ),
                )),
        const SizedBox(height: 16),
        Text('See the similarity.', style: head(26)),
        const SizedBox(height: 6),
        const Text(
            'Not just read the score — compare the two environments, characteristic by characteristic.',
            style: TextStyle(color: muted)),
        const SizedBox(height: 14),
        if (!widget.site.live)
        for (final r in const [
          ('Terrain roughness', '90', '92'),
          ('Temperature', '-2°C', '-49°C'),
          ('Aridity', '96', '98'),
          ('Bare ground', '94', '99'),
        ])
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Text(r.$1, style: mono(10)),
                const Spacer(),
                Text('${r.$2}  →  ${r.$3}', style: mono(11, fg)),
              ])),
        Panel(
            child: Row(children: [
          Text('OVERALL FIDELITY', style: mono(10, fg)),
          const Spacer(),
          Text('${widget.site.score}', style: head(24, accent)),
        ])),
      ]),
      back: true);
}

// ───────────── 10. Science credibility ─────────────
class SciencePage extends StatefulWidget {
  final bool standalone;
  const SciencePage({super.key, this.standalone = false});
  @override
  State<SciencePage> createState() => _ScienceState();
}

class _ScienceState extends State<SciencePage> {
  String? _selected; // provenance chip currently opened
  bool _showMore = false;

  void _pick(String name) =>
      setState(() => _selected = _selected == name ? null : name);

  Widget _selectedInfo() {
    ProvSource? s;
    for (final x in [...kSourcesMain, ...kSourcesMore]) {
      if (x.name == _selected) s = x;
    }
    if (s == null) return const SizedBox(width: double.infinity);
    return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Panel(
            stars: false,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(s.name, style: mono(11, accent))),
                GestureDetector(
                    onTap: () => setState(() => _selected = null),
                    child: const Icon(Icons.close, size: 16, color: muted)),
              ]),
              const SizedBox(height: 6),
              Text(s.full,
                  style: const TextStyle(fontWeight: FontWeight.w700, color: fg)),
              const SizedBox(height: 10),
              Text('WHAT IT IS', style: mono(9)),
              const SizedBox(height: 4),
              Text(s.what, style: const TextStyle(color: fg, height: 1.4)),
              const SizedBox(height: 10),
              Text('USED IN GEOX FOR', style: mono(9)),
              const SizedBox(height: 4),
              Text(s.usedFor, style: const TextStyle(color: fg, height: 1.4)),
            ])));
  }

  static const _limits = [
    (Icons.public, 'Gravity'),
    (Icons.compress, 'Atmospheric pressure'),
    (Icons.warning_amber_rounded, 'Radiation'),
    (Icons.blur_on, 'Vacuum'),
    (Icons.air, 'Atmosphere'),
    (Icons.thermostat, 'Thermal scale'),
  ];

  static const _sources = [
    ('MODIS', 'Land Surface Temp', 'Thermal similarity'),
    ('MOLA', 'Slope · roughness', 'Terrain similarity'),
    ('WORLDCOVER', 'Bare / sparse cover', 'Bare-ground similarity'),
  ];

  @override
  Widget build(BuildContext c) => frame(
      c,
      'SCIENCE',
      ListView(children: [
        Row(children: [
          const Icon(Icons.warning_amber_rounded, size: 15, color: Color(0xFFD9A441)),
          const SizedBox(width: 6),
          Text('HONEST LIMITS', style: mono(10, const Color(0xFFD9A441))),
        ]),
        const SizedBox(height: 10),
        Text('No Earth site can\nfully replicate\nanother world.', style: head(30)),
        const SizedBox(height: 12),
        const Text(
            'Analogues reproduce selected environmental characteristics — but not the conditions below.',
            style: TextStyle(color: muted, height: 1.4)),
        const SizedBox(height: 16),
        Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('NOT REPRODUCED', style: mono(10, fg)),
          const SizedBox(height: 10),
          for (final l in _limits) _limitRow(l.$1, l.$2),
        ])),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [accent.withAlpha(50), accent.withAlpha(10)]),
              border: Border.all(color: accent.withAlpha(90))),
          child: const Text(
              'Analogues help us test what we can reproduce on Earth — before we leave it.',
              style: TextStyle(fontWeight: FontWeight.w600, height: 1.4, color: fg)),
        ),
        const SizedBox(height: 20),
        Text('DATA PROVENANCE', style: mono(10, fg)),
        const SizedBox(height: 4),
        Text('Tap a source to see what it is and how GeoX uses it.', style: mono(9)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final s in kSourcesMain)
            ProvenanceChip(
                text: s.name,
                selected: _selected == s.name,
                onTap: () => _pick(s.name)),
          ProvenanceChip(
              text: _showMore ? 'SHOW LESS' : '+${kSourcesMore.length} MORE',
              selected: _showMore,
              onTap: () => setState(() {
                    _showMore = !_showMore;
                    if (!_showMore &&
                        kSourcesMore.any((x) => x.name == _selected)) {
                      _selected = null;
                    }
                  })),
          if (_showMore)
            for (final s in kSourcesMore)
              ProvenanceChip(
                  text: s.name,
                  selected: _selected == s.name,
                  onTap: () => _pick(s.name)),
        ]),
        AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: _selectedInfo()),
        const SizedBox(height: 14),
        Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('SOURCE → FEATURE → ANALYSIS', style: mono(10, fg)),
          const SizedBox(height: 10),
          for (final r in _sources) _row(r.$1, r.$2, r.$3),
        ])),
        const SizedBox(height: 14),
        Btn('OPEN GLOSSARY', () => go(c, const GlossaryScreen()), primary: false),
        const SizedBox(height: 20),
      ]),
      back: widget.standalone);

  Widget _limitRow(IconData icon, String label) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(color: line),
              boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 3))]),
          child: Icon(icon, size: 15, color: accent),
        ),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: fg)),
      ]));

  Widget _row(String a, String b, String d) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text.rich(TextSpan(children: [
        TextSpan(text: '$a → ', style: mono(11, teal)),
        TextSpan(text: '$b → ', style: mono(11, fg)),
        TextSpan(text: d, style: mono(11, accent)),
      ])));
}

// ───────────── Painters ─────────────
// Procedural Mars surface map (equirectangular), generated once in an isolate.
const int _kTexW = 512, _kTexH = 256;

double _hash3(int x, int y, int z) {
  var n = (x * 374761393 + y * 668265263 + z * 1274126177 + 1013904223) &
      0x7fffffff;
  n = ((n ^ (n >> 13)) * 1274126177) & 0x7fffffff;
  n = n ^ (n >> 16);
  return (n & 0xFFFFFF) / 16777215.0;
}

double _mix(double a, double b, double t) => a + (b - a) * t;

double _vnoise(double x, double y, double z) {
  final xi = x.floor(), yi = y.floor(), zi = z.floor();
  final fx = x - xi, fy = y - yi, fz = z - zi;
  final sx = fx * fx * (3 - 2 * fx),
      sy = fy * fy * (3 - 2 * fy),
      sz = fz * fz * (3 - 2 * fz);
  return _mix(
      _mix(_mix(_hash3(xi, yi, zi), _hash3(xi + 1, yi, zi), sx),
          _mix(_hash3(xi, yi + 1, zi), _hash3(xi + 1, yi + 1, zi), sx), sy),
      _mix(_mix(_hash3(xi, yi, zi + 1), _hash3(xi + 1, yi, zi + 1), sx),
          _mix(_hash3(xi, yi + 1, zi + 1), _hash3(xi + 1, yi + 1, zi + 1), sx),
          sy),
      sz);
}

double _fbm(double x, double y, double z, int oct) {
  var s = 0.0, a = 0.5, f = 1.0, t = 0.0;
  for (var i = 0; i < oct; i++) {
    final o = i * 17.3;
    s += a * _vnoise(x * f + o, y * f + o, z * f + o);
    t += a;
    a *= 0.5;
    f *= 2.03;
  }
  return s / t;
}

double _sstep(double a, double b, double x) {
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0).toDouble();
  return t * t * (3 - 2 * t);
}

Uint8List _marsTexturePixels(int _) {
  const w = _kTexW, h = _kTexH;
  final cosLon = Float64List(w), sinLon = Float64List(w);
  for (var x = 0; x < w; x++) {
    final lon = (x + .5) / w * 2 * math.pi - math.pi;
    cosLon[x] = math.cos(lon);
    sinLon[x] = math.sin(lon);
  }

  // Impact craters: bowl + raised rim, lit from the north-west.
  final shade = Float32List(w * h)..fillRange(0, w * h, 1.0);
  final rnd = math.Random(7);
  for (var i = 0; i < 260; i++) {
    final vy = rnd.nextDouble() * 2 - 1;
    final a = rnd.nextDouble() * 2 * math.pi;
    final rr = math.sqrt(1 - vy * vy);
    final vx = rr * math.cos(a), vz = rr * math.sin(a);
    final rc = 0.010 + 0.055 * math.pow(rnd.nextDouble(), 2.4);
    final latC = math.asin(vy);
    final y0 = ((math.pi / 2 - (latC + rc * 1.7)) / math.pi * h)
        .floor()
        .clamp(0, h - 1)
        .toInt();
    final y1 = ((math.pi / 2 - (latC - rc * 1.7)) / math.pi * h)
        .ceil()
        .clamp(0, h - 1)
        .toInt();
    for (var y = y0; y <= y1; y++) {
      final lat = math.pi / 2 - (y + .5) / h * math.pi;
      final cl = math.cos(lat), sl = math.sin(lat);
      for (var x = 0; x < w; x++) {
        final px = cl * cosLon[x], py = sl, pz = cl * sinLon[x];
        final dx = px - vx, dy = py - vy, dz = pz - vz;
        final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
        final t = dist / rc;
        if (t >= 1.6) continue;
        var hp = t < 1 ? 2 * t : 0.0;
        final q = (t - 1) / 0.14;
        hp += 0.6 * math.exp(-q * q) * (-2 * (t - 1) / 0.0196);
        final lx = 0.7 * sinLon[x] - 0.7 * sl * cosLon[x];
        final ly = 0.7 * cl;
        final lz = -0.7 * cosLon[x] - 0.7 * sl * sinLon[x];
        final dn = (dx * lx + dy * ly + dz * lz) / (dist < 1e-6 ? 1e-6 : dist);
        final f = (1 - 0.028 * 8 * hp * dn).clamp(0.55, 1.5).toDouble();
        shade[y * w + x] *= f * (t < 1 ? 0.93 + 0.07 * t : 1.0);
      }
    }
  }

  final hla = -42 * math.pi / 180, hlo = 70 * math.pi / 180;
  final hx = math.cos(hla) * math.cos(hlo),
      hy = math.sin(hla),
      hz = math.cos(hla) * math.sin(hlo);
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final lat = math.pi / 2 - (y + .5) / h * math.pi;
    final cl = math.cos(lat), sl = math.sin(lat);
    final latDeg = lat * 180 / math.pi;
    for (var x = 0; x < w; x++) {
      final px = cl * cosLon[x], py = sl, pz = cl * sinLon[x];
      final lon = (x + .5) / w * 2 * math.pi - math.pi;

      // Bright ochre plains vs. dark basaltic regions.
      final warp = _fbm(px * 3 + 9, py * 3 + 9, pz * 3 + 9, 3);
      final dk = _sstep(
          0.47,
          0.60,
          _fbm(px * 2.2 + warp * 1.2 + 1.7, py * 2.2 + warp * 1.2 + 1.7,
              pz * 2.2 + warp * 1.2 + 1.7, 4));
      final dkw = dk * (0.35 + 0.65 * _sstep(-1.0, 0.2, sl + 0.3)) * 0.9;
      var r = 238 * (1 - dkw) + 122 * dkw;
      var g = 126 * (1 - dkw) + 58 * dkw;
      var b = 78 * (1 - dkw) + 40 * dkw;

      final tint = _fbm(px * 3.5 + 5, py * 3.5 + 5, pz * 3.5 + 5, 3);
      final tt = (tint - .5) * 0.10;
      r *= 1 + tt;
      g *= 1 + tt * 0.2;
      b *= 1 - tt * 0.8;

      final det = _fbm(px * 8, py * 8, pz * 8, 4);
      final fine = _fbm(px * 26, py * 26, pz * 26, 3);
      final lum = (0.88 + 0.40 * det) * (0.92 + 0.16 * fine);
      r *= lum;
      g *= lum;
      b *= lum;

      // Hellas-style bright basin.
      final hd = math.sqrt((px - hx) * (px - hx) +
          (py - hy) * (py - hy) +
          (pz - hz) * (pz - hz));
      final hel = math.exp(-(hd / 0.30) * (hd / 0.30));
      r += 44 * hel;
      g += 36 * hel;
      b += 26 * hel;

      // Valles-style canyon streak near the equator.
      final vq = (latDeg + 8 + 3 * math.sin(lon * 7)) / 2.2;
      final valles = math.exp(-vq * vq) *
          _sstep(-1.7, -1.4, lon) *
          (1 - _sstep(-0.9, -0.7, lon));
      final vk = 1 - 0.52 * valles;
      r *= vk;
      g *= vk;
      b *= vk;

      final sh = shade[y * w + x];
      r *= sh;
      g *= sh;
      b *= sh;

      // Polar ice caps with ragged edges.
      if (lat.abs() > 1.05) {
        final edgeN =
            80 * math.pi / 180 + (_fbm(px * 6 + 2, py * 6 + 2, pz * 6 + 2, 3) - .5) * 0.14;
        final edgeS =
            -84 * math.pi / 180 - (_fbm(px * 6 + 8, py * 6 + 8, pz * 6 + 8, 3) - .5) * 0.12;
        final cap = math.max(_sstep(0, 0.03, lat - edgeN), _sstep(0, 0.03, edgeS - lat));
        final k = 0.9 + 0.1 * fine;
        r = r * (1 - cap) + 238 * cap * k;
        g = g * (1 - cap) + 232 * cap * k;
        b = b * (1 - cap) + 224 * cap * k;
      }

      final o = (y * w + x) * 4;
      out[o] = r.clamp(0, 255).toInt();
      out[o + 1] = g.clamp(0, 255).toInt();
      out[o + 2] = b.clamp(0, 255).toInt();
      out[o + 3] = 255;
    }
  }
  return out;
}

class MarsPainter extends CustomPainter {
  final double rotation;
  final ui.ImageShader? surface;
  MarsPainter(this.rotation, this.surface);

  static const int _lonSeg = 72, _latSeg = 36;
  static const int _nv = (_lonSeg + 1) * (_latSeg + 1);

  // Sphere mesh: texture coordinates and unit-sphere positions (built once).
  static final Float32List _uv = () {
    final a = Float32List(_nv * 2);
    var k = 0;
    for (var j = 0; j <= _latSeg; j++) {
      for (var i = 0; i <= _lonSeg; i++) {
        a[k++] = i / _lonSeg * _kTexW;
        a[k++] = j / _latSeg * _kTexH;
      }
    }
    return a;
  }();
  static final Float32List _unit = () {
    final a = Float32List(_nv * 3);
    var k = 0;
    for (var j = 0; j <= _latSeg; j++) {
      final lat = math.pi / 2 - j / _latSeg * math.pi;
      for (var i = 0; i <= _lonSeg; i++) {
        final lon = -math.pi + i / _lonSeg * 2 * math.pi;
        a[k++] = math.cos(lat) * math.cos(lon);
        a[k++] = math.sin(lat);
        a[k++] = math.cos(lat) * math.sin(lon);
      }
    }
    return a;
  }();

  // Sun direction: upper-left, toward the viewer.
  static final List<double> _sun = () {
    const x = -0.62, y = 0.5, z = 0.6;
    final n = math.sqrt(x * x + y * y + z * z);
    return [x / n, y / n, z / n];
  }();

  @override
  void paint(Canvas cv, Size s) {
    final c = s.center(Offset.zero);
    final r = s.shortestSide / 2;
    final rect = Rect.fromCircle(center: c, radius: r);

    cv.save();
    cv.clipPath(Path()..addOval(rect));
    cv.drawCircle(c, r, Paint()..color = const Color(0xFF9A4526));

    final sh = surface;
    if (sh != null) {
      _drawMesh(cv, c, r, sh);
    } else {
      // Shown for a moment while the surface map is being generated.
      cv.drawCircle(
          c,
          r,
          Paint()
            ..shader = const RadialGradient(
              center: Alignment(-.42, -.46),
              radius: 1.05,
              colors: [Color(0xFFD08A5C), Color(0xFF9C4E2C), Color(0xFF2E140B)],
              stops: [0, .55, 1],
            ).createShader(rect));
    }

    // Limb darkening for roundness.
    cv.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [Colors.transparent, const Color(0xFF3A160A).withAlpha(60)],
            stops: const [0.80, 1],
          ).createShader(rect));
    // Thin dusty atmosphere catching the light on the sun side.
    cv.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-.35, -.4),
            radius: 1.0,
            colors: [Colors.transparent, const Color(0xFFFFB98A).withAlpha(95)],
            stops: const [0.78, 1.0],
          ).createShader(rect));
    cv.restore();
  }

  void _drawMesh(Canvas cv, Offset c, double r, ui.ImageShader surface) {
    final ca = math.cos(rotation), sa = math.sin(rotation);
    const tilt = 0.5, roll = -0.3; // axial tilt toward viewer, slight lean
    final ct = math.cos(tilt), st = math.sin(tilt);
    final cr = math.cos(roll), sr = math.sin(roll);

    final pos = Float32List(_nv * 2);
    final col = Int32List(_nv);
    final zs = Float32List(_nv);
    for (var v = 0; v < _nv; v++) {
      final x = _unit[v * 3], y = _unit[v * 3 + 1], z = _unit[v * 3 + 2];
      final x1 = x * ca + z * sa, z1 = -x * sa + z * ca; // spin
      final y2 = y * ct - z1 * st, z2 = y * st + z1 * ct; // tilt
      final x3 = x1 * cr - y2 * sr, y3 = x1 * sr + y2 * cr; // roll
      pos[v * 2] = c.dx + x3 * r;
      pos[v * 2 + 1] = c.dy - y3 * r;
      zs[v] = z2;
      final dot = x3 * _sun[0] + y3 * _sun[1] + z2 * _sun[2];
      final lam = ((dot + 1.0) / 2.0).clamp(0.0, 1.0).toDouble();
      final k = (0.64 + 0.36 * math.pow(lam, 0.8)).clamp(0.0, 1.0).toDouble();
      col[v] = (0xFF << 24) |
          ((255 * k).round() << 16) |
          ((250 * k).round() << 8) |
          (242 * k).round();
    }

    final idx = Uint16List(_lonSeg * _latSeg * 6);
    var n = 0;
    for (var j = 0; j < _latSeg; j++) {
      for (var i = 0; i < _lonSeg; i++) {
        final a = j * (_lonSeg + 1) + i, b = a + 1;
        final d = a + _lonSeg + 1, e = d + 1;
        if (zs[a] + zs[b] + zs[d] > 0) {
          idx[n++] = a;
          idx[n++] = d;
          idx[n++] = b;
        }
        if (zs[b] + zs[d] + zs[e] > 0) {
          idx[n++] = b;
          idx[n++] = d;
          idx[n++] = e;
        }
      }
    }

    final verts = ui.Vertices.raw(ui.VertexMode.triangles, pos,
        textureCoordinates: _uv, colors: col, indices: idx.sublist(0, n));
    cv.drawVertices(
        verts,
        BlendMode.modulate,
        Paint()
          ..shader = surface
          ..filterQuality = FilterQuality.medium
          ..isAntiAlias = true);
    verts.dispose();
  }

  @override
  bool shouldRepaint(covariant MarsPainter old) =>
      old.rotation != rotation || old.surface != surface;
}

/// A fingerprint radar chart with a rotating "lighthouse" light sweep —
/// a bright beam rotates around the center, and each vertex briefly glows
/// brighter (a "ping") as the beam passes over it, like a radar scan.
class FidelityRadar extends StatefulWidget {
  final List<double> values; // 0..1 per axis
  final List<String> labels;
  final double height;
  const FidelityRadar(
      {super.key, required this.values, required this.labels, this.height = 210});
  @override
  State<FidelityRadar> createState() => _FidelityRadarState();
}

class _FidelityRadarState extends State<FidelityRadar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    // One full sweep every 6 seconds — a brisk lighthouse-style rotation.
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 6))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: widget.height,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => CustomPaint(
              size: Size.infinite,
              painter: RadarPainter(widget.values, widget.labels,
                  sweep: _ctrl.value * 2 * math.pi)),
        ),
      );
}

class RadarPainter extends CustomPainter {
  final List<double> v; // 0..1 fraction per axis
  final List<String> lab;
  final double sweep; // current rotation of the light sweep, in radians
  RadarPainter(this.v, this.lab, {this.sweep = 0});

  @override
  void paint(Canvas cv, Size s) {
    final center = s.center(Offset.zero);
    final r = s.shortestSide / 2 - 28;
    final n = v.length;
    if (n < 3) return;

    Offset pt(int i, double k) {
      final a = -math.pi / 2 + 2 * math.pi * i / n;
      return center + Offset(math.cos(a), math.sin(a)) * r * k;
    }

    // Rotating lighthouse sweep, drawn first so the grid and polygon sit on
    // top of it.
    cv.drawCircle(
        center,
        r,
        Paint()
          ..shader = SweepGradient(
            colors: [
              accent.withAlpha(0),
              accent.withAlpha(0),
              accent.withAlpha(15), // dim comet tail
              accent.withAlpha(150), // bright leading edge
              accent.withAlpha(0),
            ],
            stops: const [0.0, 0.68, 0.85, 0.985, 1.0],
            transform: GradientRotation(sweep),
          ).createShader(Rect.fromCircle(center: center, radius: r)));

    // Bright thin beam line at the exact sweep angle, from center outward.
    final beamEnd = center + Offset(math.cos(sweep), math.sin(sweep)) * r;
    cv.drawLine(
        center,
        beamEnd,
        Paint()
          ..shader = LinearGradient(colors: [accent.withAlpha(235), accent.withAlpha(0)])
              .createShader(Rect.fromPoints(center, beamEnd))
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round);

    // Small bright core at the center, like a lighthouse lamp.
    cv.drawCircle(
        center,
        5,
        Paint()
          ..color = accent.withAlpha(235)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));

    // Grid rings + spokes.
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..color = line
      ..strokeWidth = 1;
    for (var k = 1; k <= 4; k++) {
      final p = Path();
      for (var i = 0; i < n; i++) {
        final o = pt(i, k / 4);
        i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
      }
      cv.drawPath(p..close(), grid);
    }
    for (var i = 0; i < n; i++) {
      cv.drawLine(center, pt(i, 1), grid);
    }

    // Data polygon.
    final poly = Path();
    final points = <Offset>[];
    for (var i = 0; i < n; i++) {
      final o = pt(i, v[i]);
      points.add(o);
      i == 0 ? poly.moveTo(o.dx, o.dy) : poly.lineTo(o.dx, o.dy);
    }
    poly.close();
    cv.drawPath(poly, Paint()..color = accent.withAlpha(70));
    cv.drawPath(
        poly,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = accent
          ..strokeWidth = 2);

    // Vertex dots, each with a "ping" halo that brightens as the sweep
    // beam passes over it.
    for (var i = 0; i < n; i++) {
      final angle = -math.pi / 2 + 2 * math.pi * i / n;
      var diff = (angle - sweep) % (2 * math.pi);
      if (diff < 0) diff += 2 * math.pi;
      if (diff > math.pi) diff = 2 * math.pi - diff;
      const pingWindow = 0.5; // radians of influence around the beam
      final intensity = (1 - (diff / pingWindow)).clamp(0.0, 1.0);
      if (intensity > 0) {
        cv.drawCircle(
            points[i],
            3.5 + intensity * 10,
            Paint()
              ..color = Colors.white.withAlpha((150 * intensity).round())
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + intensity * 6));
      }
      cv.drawCircle(points[i], 3.5, Paint()..color = accent);
    }

    // Axis labels.
    for (var i = 0; i < n; i++) {
      final tp = TextPainter(
          text: TextSpan(text: lab[i], style: mono(9)),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(cv, pt(i, 1.2) - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant RadarPainter old) =>
      old.v != v || old.sweep != sweep;
}

class LinePainter extends CustomPainter {
  final List<double> v;
  LinePainter(this.v);
  @override
  void paint(Canvas cv, Size s) {
    final lo = v.reduce(math.min) - 5, hi = v.reduce(math.max) + 5;
    Offset pt(int i) => Offset(
        s.width * i / (v.length - 1), s.height * (1 - (v[i] - lo) / (hi - lo)));
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < v.length; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    final fill = Path.from(path)
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
    cv.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [accent.withAlpha(110), Colors.transparent])
              .createShader(Offset.zero & s));
    cv.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = accent);
    cv.drawCircle(pt(v.length - 1), 5, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter o) => true;
}

class MapPainter extends CustomPainter {
  @override
  void paint(Canvas cv, Size s) {
    final g = Paint()
      ..color = line.withAlpha(120)
      ..strokeWidth = 1;
    for (var x = 0.0; x < s.width; x += 36) {
      cv.drawLine(Offset(x, 0), Offset(x, s.height), g);
    }
    for (var y = 0.0; y < s.height; y += 36) {
      cv.drawLine(Offset(0, y), Offset(s.width, y), g);
    }
    final land = Paint()..color = const Color(0xFF141C2B);
    Path blob(List<Offset> f) {
      final p = Path();
      for (var i = 0; i < f.length; i++) {
        final o = Offset(f[i].dx * s.width, f[i].dy * s.height);
        i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
      }
      return p..close();
    }

    cv.drawPath(blob(const [Offset(.15, .1), Offset(.45, .05), Offset(.5, .45), Offset(.3, .55), Offset(.12, .35)]), land);
    cv.drawPath(blob(const [Offset(.35, .6), Offset(.55, .58), Offset(.5, .95), Offset(.38, .9)]), land);
    cv.drawPath(blob(const [Offset(.6, .12), Offset(.92, .1), Offset(.95, .5), Offset(.7, .55), Offset(.62, .35)]), land);
  }

  @override
  bool shouldRepaint(covariant CustomPainter o) => false;
}


// ───────────── Top-bar actions: HOME button + account ─────────────
class _HomeAndAccount extends StatelessWidget {
  final bool showAccount;
  const _HomeAndAccount({this.showAccount = true});

  @override
  Widget build(BuildContext c) => Row(mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(
          onTap: () => Navigator.of(c).popUntil((r) => r.isFirst),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: accent.withAlpha(140)),
                boxShadow: [BoxShadow(color: accent.withAlpha(40), blurRadius: 8)]),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.home_outlined, size: 14, color: accent),
              const SizedBox(width: 6),
              Text('HOME', style: mono(10, accent)),
            ]),
          ),
        ),
        if (showAccount) ...[
          const SizedBox(width: 8),
          ValueListenableBuilder<AppUser?>(
            valueListenable: Auth.user,
            builder: (_, u, __) => GestureDetector(
              onTap: () =>
                  go(c, u == null ? const LoginScreen() : const ProfileScreen()),
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: u == null ? card : accent,
                    border: Border.all(color: u == null ? line : accent)),
                child: u == null
                    ? const Icon(Icons.person_outline, size: 16, color: muted)
                    : Text(u.initial,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 13, color: Colors.black)),
              ),
            ),
          ),
        ],
      ]);
}

// ───────────── Live results from the GeoX server ─────────────
class _LiveNote extends StatefulWidget {
  final List<String> notes;
  final bool bundled;
  const _LiveNote(this.notes, {this.bundled = false});
  @override
  State<_LiveNote> createState() => _LiveNoteState();
}

class _LiveNoteState extends State<_LiveNote> {
  bool _open = false;
  @override
  Widget build(BuildContext c) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Panel(
          stars: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.bolt, size: 14, color: teal),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(
                      widget.bundled
                          ? 'VALIDATED DATA · BUNDLED WITH THE APP · WORKS OFFLINE'
                          : 'LIVE · SCORED BY THE GEOX SERVER · ENVIRONMENT ONLY',
                      style: mono(9, teal))),
            ]),
            if (widget.notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              GestureDetector(
                  onTap: () => setState(() => _open = !_open),
                  child: Text(
                      _open
                          ? 'HIDE ASSUMPTIONS'
                          : 'SHOW ASSUMPTIONS (${widget.notes.length})',
                      style: mono(9, accent))),
              if (_open)
                for (final n in widget.notes)
                  Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(n,
                          style: const TextStyle(
                              color: muted, fontSize: 12, height: 1.35))),
            ],
          ])));
}

/// Asks the server to rank the Earth sites for a custom coordinate, then shows
/// the usual results screens with those live results.
class OpenTargetLoader extends StatefulWidget {
  final OpenTargetQuery? query;
  final String? targetId;
  final String name, planet;
  const OpenTargetLoader(
      {super.key,
      this.query,
      this.targetId,
      required this.name,
      required this.planet});
  @override
  State<OpenTargetLoader> createState() => _OpenTargetLoaderState();
}

class _OpenTargetLoaderState extends State<OpenTargetLoader> {
  List<Site>? _sites;
  List<String> _notes = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.targetId;
      OpenTargetResult r;
      if (id != null) {
        // Standard targets: the validated data inside the app comes first, so
        // this works with no server. The server is only a fallback.
        try {
          r = await BundledData.rankingFor(id);
        } catch (_) {
          if (!GeoXApi.configured) rethrow;
          r = await GeoXApi.scoreTarget(id);
          r = OpenTargetResult(r.ranked, const [
            'The bundled data was not available, so this was scored live by the server. Environment only.',
            'Scores are rescaled across the candidate set, so they rank within this result and are not an absolute physical measurement.',
          ], r.earthSource);
        }
      } else {
        r = await GeoXApi.openTarget(
            planet: widget.planet.toLowerCase(), query: widget.query!);
      }
      final list = [for (final j in r.ranked) siteFromRanked(j)];
      if (!mounted) return;
      setState(() {
        _sites = list;
        _notes = r.caveats;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is ApiException
          ? e.message
          : 'The result could not be read.');
    }
  }

  @override
  Widget build(BuildContext c) {
    final list = _sites;
    if (list != null) {
      return MainShell(
          targetName: widget.name,
          planet: widget.planet,
          openSites: list,
          notes: _notes);
    }
    final err = _error;
    return frame(
        c,
        'FINDING ANALOGUES',
        err == null
            ? const LoadingView(message: 'Scoring the Earth sites…')
            : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                ErrorView(
                    message: err,
                    onRetry: () {
                      setState(() => _error = null);
                      _load();
                    }),
                if (widget.targetId != null) ...[
                  const SizedBox(height: 16),
                  Btn('USE OFFLINE PREVIEW INSTEAD', () {
                    Session.targetName = widget.name;
                    Session.planet = widget.planet;
                    go(c, MainShell(targetName: widget.name, planet: widget.planet));
                  }, primary: false),
                ],
              ]),
        back: true);
  }
}

// ───────────── Account: model + in-memory store ─────────────
// Frontend only: accounts live in memory (lost on app restart). Replace the
// bodies of register / login / logout / rename with real backend calls later.
class AppUser {
  final String name, email;
  final DateTime joined;
  const AppUser(this.name, this.email, this.joined);
  String get initial => name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
  AppUser copyWith({String? name}) => AppUser(name ?? this.name, email, joined);
}

class Auth {
  static final ValueNotifier<AppUser?> user = ValueNotifier<AppUser?>(null);

  /// Supabase access token of the signed-in user. The GeoX API expects it as
  /// `Authorization: Bearer <token>`. Null when signed out.
  static String? accessToken;

  // Kept on the device so a restart or page refresh does not sign the person
  // out. The refresh token is what Supabase exchanges for a new access token.
  static String? _refreshToken;
  static DateTime? _expires;
  static const _kRefresh = 'geox_refresh_token';

  static Future<void> _persist(Map<String, dynamic> b) async {
    _refreshToken = b['refresh_token']?.toString();
    final at = b['expires_at'], inS = b['expires_in'];
    _expires = at is num
        ? DateTime.fromMillisecondsSinceEpoch(at.toInt() * 1000)
        : inS is num
            ? DateTime.now().add(Duration(seconds: inS.toInt()))
            : null;
    final rt = _refreshToken;
    if (rt == null) return;
    try {
      await (await SharedPreferences.getInstance()).setString(_kRefresh, rt);
    } catch (_) {}
  }

  static Future<void> _forget() async {
    _refreshToken = null;
    _expires = null;
    try {
      await (await SharedPreferences.getInstance()).remove(_kRefresh);
    } catch (_) {}
  }

  /// Swaps a refresh token for a new session. True on success.
  static Future<bool> _applyRefresh(String rt) async {
    final (status, b) = await _send(() => http.post(
        _u('/token', {'grant_type': 'refresh_token'}),
        headers: _headers(),
        body: jsonEncode({'refresh_token': rt})));
    final token = b['access_token']?.toString();
    if (status >= 200 && status < 300 && token != null) {
      accessToken = token;
      final u = b['user'];
      if (u is Map<String, dynamic>) user.value = _toUser(u);
      await _persist(b);
      return true;
    }
    // The server said no (expired or already used): stop trying it.
    // If it simply could not be reached (status 0), keep it for next time.
    if (status >= 400 && status < 500) await _forget();
    return false;
  }

  /// Called once at startup.
  static Future<void> restore() async {
    if (!_configured) return;
    try {
      final rt = (await SharedPreferences.getInstance()).getString(_kRefresh);
      if (rt == null || rt.isEmpty) return;
      _refreshToken = rt;
      await _applyRefresh(rt)
          .timeout(const Duration(seconds: 6), onTimeout: () => false);
    } catch (_) {}
  }

  /// A token that is valid right now, refreshing it first if it is about to
  /// expire (access tokens last about an hour). Null when signed out.
  static Future<String?> freshToken() async {
    final t = accessToken;
    if (t == null) return null;
    final e = _expires;
    if (e != null && e.isAfter(DateTime.now().add(const Duration(seconds: 60)))) {
      return t;
    }
    final rt = _refreshToken;
    if (rt == null) return t;
    return await _applyRefresh(rt) ? accessToken : t;
  }

  static bool get _configured =>
      AppConfig.supabaseUrl.isNotEmpty && AppConfig.supabaseAnonKey.isNotEmpty;

  static Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse('${AppConfig.supabaseUrl}/auth/v1$path').replace(queryParameters: q);

  static Map<String, String> _headers([String? token]) => {
        'apikey': AppConfig.supabaseAnonKey,
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  static AppUser _toUser(Map<String, dynamic> j, {String? fallbackName}) {
    final email = (j['email'] ?? '').toString();
    final meta = j['user_metadata'];
    var name = meta is Map ? (meta['name'] ?? '').toString().trim() : '';
    if (name.isEmpty) {
      name = fallbackName ??
          (email.contains('@') ? email.split('@').first : 'Explorer');
    }
    final joined =
        DateTime.tryParse((j['created_at'] ?? '').toString())?.toLocal() ??
            DateTime.now();
    return AppUser(name, email.toLowerCase(), joined);
  }

  /// Runs one request and returns (status, json body). Never throws:
  /// status 0 means the server could not be reached.
  static Future<(int, Map<String, dynamic>)> _send(
      Future<http.Response> Function() call) async {
    try {
      final res = await call().timeout(const Duration(seconds: 20));
      var body = <String, dynamic>{};
      try {
        final d = jsonDecode(res.body);
        if (d is Map<String, dynamic>) body = d;
      } catch (_) {}
      return (res.statusCode, body);
    } catch (_) {
      return (0, <String, dynamic>{});
    }
  }

  static String _why(int status, Map<String, dynamic> b, String fallback) {
    if (status == 0) return '$fallback The server could not be reached.';
    final raw = (b['error_description'] ?? b['msg'] ?? b['message'] ?? b['error'] ?? '')
        .toString();
    final low = raw.toLowerCase();
    if (low.contains('already registered')) {
      return 'An account with this email already exists.';
    }
    if (low.contains('invalid login credentials')) {
      return 'Incorrect email or password.';
    }
    if (low.contains('email not confirmed')) {
      return 'Please confirm your email first. Check your inbox for the link.';
    }
    if (status == 429) return 'Too many attempts. Wait a minute and try again.';
    return raw.isEmpty ? fallback : raw;
  }

  /// Returns an error message, or null on success. On success the user is
  /// signed in, unless the project requires email confirmation: then `user`
  /// stays null and the screen tells the person to check their inbox.
  static Future<String?> register(String name, String email, String password) async {
    if (!_configured) return 'Sign-in is not configured in this build.';
    final (status, b) = await _send(() => http.post(_u('/signup'),
        headers: _headers(),
        body: jsonEncode({
          'email': email.trim(),
          'password': password,
          'data': {'name': name.trim()},
        })));
    if (status < 200 || status >= 300) {
      return _why(status, b, 'Could not create the account.');
    }
    final token = b['access_token']?.toString();
    if (token == null) return null; // email confirmation is required
    accessToken = token;
    await _persist(b);
    final u = b['user'];
    user.value = _toUser(u is Map<String, dynamic> ? u : b, fallbackName: name.trim());
    return null;
  }

  /// Returns an error message, or null on success.
  static Future<String?> login(String email, String password) async {
    if (!_configured) return 'Sign-in is not configured in this build.';
    final (status, b) = await _send(() => http.post(
        _u('/token', {'grant_type': 'password'}),
        headers: _headers(),
        body: jsonEncode({'email': email.trim(), 'password': password})));
    if (status < 200 || status >= 300) return _why(status, b, 'Could not log in.');
    final token = b['access_token']?.toString();
    final u = b['user'];
    if (token == null || u is! Map<String, dynamic>) {
      return 'Unexpected reply from the sign-in service.';
    }
    accessToken = token;
    await _persist(b);
    user.value = _toUser(u);
    return null;
  }

  static void logout() {
    final t = accessToken;
    accessToken = null;
    user.value = null;
    _forget();
    if (t != null && _configured) _logoutRemote(t);
  }

  // Best effort: the person is signed out on the device either way.
  static Future<void> _logoutRemote(String token) async {
    await _send(() => http.post(_u('/logout'), headers: _headers(token)));
  }

  static void rename(String name) {
    final u = user.value;
    if (u == null) return;
    user.value = u.copyWith(name: name.trim());
    final t = accessToken;
    if (t != null && _configured) _renameRemote(name.trim(), t);
  }

  static Future<void> _renameRemote(String name, String token) async {
    await _send(() => http.put(_u('/user'),
        headers: _headers(token),
        body: jsonEncode({'data': {'name': name}})));
  }
}

String? _vName(String? v) =>
    (v == null || v.trim().length < 2) ? 'Enter your name (min 2 characters).' : null;
String? _vEmail(String? v) =>
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim())
        ? null
        : 'Enter a valid email address.';
String? _vPass(String? v) =>
    (v == null || v.length < 6) ? 'Use at least 6 characters.' : null;

void _swapTo(BuildContext c, Widget w) => Navigator.pushReplacement(
    c,
    MaterialPageRoute(
        settings: RouteSettings(name: _titleFor(w)), builder: (_) => w));

const _warn = Color(0xFFD9A441);

Widget _authField({
  required TextEditingController ctrl,
  required String label,
  required IconData icon,
  String? hint,
  TextInputType? type,
  bool obscure = false,
  Widget? suffix,
  String? Function(String?)? validator,
  TextInputAction? action,
}) {
  OutlineInputBorder b(Color col) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: col));
  return TextFormField(
    controller: ctrl,
    keyboardType: type,
    obscureText: obscure,
    validator: validator,
    textInputAction: action,
    autocorrect: false,
    enableSuggestions: !obscure,
    style: const TextStyle(color: fg, fontSize: 14),
    decoration: InputDecoration(
        labelText: label,
        labelStyle: mono(10),
        hintText: hint,
        hintStyle: mono(10),
        prefixIcon: Icon(icon, size: 18, color: muted),
        suffixIcon: suffix,
        filled: true,
        fillColor: card,
        errorStyle: const TextStyle(color: _warn, fontSize: 11),
        border: b(line),
        enabledBorder: b(line),
        focusedBorder: b(accent),
        errorBorder: b(_warn),
        focusedErrorBorder: b(_warn)),
  );
}

// ───────────── Login ─────────────
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginState();
}

class _LoginState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _hide = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await Auth.login(_email.text, _pass.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final name = Auth.user.value!.name;
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(content: Text('Welcome back, $name.')));
  }

  @override
  Widget build(BuildContext c) => frame(
      c,
      'LOGIN',
      Form(
          key: _form,
          child: ListView(children: [
            Text('WELCOME BACK', style: mono(9)),
            const SizedBox(height: 8),
            Text('Log in to\nGeoX', style: head(30)),
            const SizedBox(height: 8),
            const Text('Sign in to your account.', style: TextStyle(color: muted)),
            const SizedBox(height: 22),
            _authField(
                ctrl: _email,
                label: 'Email',
                icon: Icons.mail_outline,
                hint: 'you@example.com',
                type: TextInputType.emailAddress,
                validator: _vEmail,
                action: TextInputAction.next),
            const SizedBox(height: 12),
            _authField(
                ctrl: _pass,
                label: 'Password',
                icon: Icons.lock_outline,
                obscure: _hide,
                validator: _vPass,
                action: TextInputAction.done,
                suffix: IconButton(
                    icon: Icon(_hide ? Icons.visibility_off : Icons.visibility,
                        size: 18, color: muted),
                    onPressed: () => setState(() => _hide = !_hide))),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(children: [
                    const Icon(Icons.error_outline, size: 14, color: _warn),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_error!, style: mono(10, _warn))),
                  ])),
            const SizedBox(height: 20),
            Btn(_busy ? 'LOGGING IN…' : 'LOG IN →', _submit),
            const SizedBox(height: 10),
            Btn('CONTINUE AS GUEST', () => Navigator.pop(c), primary: false),
            const SizedBox(height: 18),
            Center(
                child: GestureDetector(
                    onTap: () => _swapTo(c, const RegisterScreen()),
                    child: Text.rich(TextSpan(style: mono(10), children: [
                      const TextSpan(text: 'NEW TO GEOX?  '),
                      TextSpan(text: 'CREATE ACCOUNT', style: mono(10, accent)),
                    ])))),
            const SizedBox(height: 24),
          ])),
      back: true,
      account: false);
}

// ───────────── Register ─────────────
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterState();
}

class _RegisterState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _hide = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await Auth.register(_name.text, _email.text, _pass.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final u = Auth.user.value;
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(
        content: Text(u == null
            ? 'Account created. Check your email to confirm it, then log in.'
            : 'Account created — welcome, ${u.name}.')));
  }

  @override
  Widget build(BuildContext c) => frame(
      c,
      'REGISTER',
      Form(
          key: _form,
          child: ListView(children: [
            Text('JOIN GEOX', style: mono(9)),
            const SizedBox(height: 8),
            Text('Create your\naccount', style: head(30)),
            const SizedBox(height: 8),
            const Text('It only takes a few seconds.', style: TextStyle(color: muted)),
            const SizedBox(height: 22),
            _authField(
                ctrl: _name,
                label: 'Full name',
                icon: Icons.person_outline,
                validator: _vName,
                action: TextInputAction.next),
            const SizedBox(height: 12),
            _authField(
                ctrl: _email,
                label: 'Email',
                icon: Icons.mail_outline,
                hint: 'you@example.com',
                type: TextInputType.emailAddress,
                validator: _vEmail,
                action: TextInputAction.next),
            const SizedBox(height: 12),
            _authField(
                ctrl: _pass,
                label: 'Password',
                icon: Icons.lock_outline,
                obscure: _hide,
                validator: _vPass,
                action: TextInputAction.next,
                suffix: IconButton(
                    icon: Icon(_hide ? Icons.visibility_off : Icons.visibility,
                        size: 18, color: muted),
                    onPressed: () => setState(() => _hide = !_hide))),
            const SizedBox(height: 12),
            _authField(
                ctrl: _confirm,
                label: 'Confirm password',
                icon: Icons.lock_outline,
                obscure: _hide,
                validator: (v) => v != _pass.text ? 'Passwords do not match.' : null,
                action: TextInputAction.done),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(children: [
                    const Icon(Icons.error_outline, size: 14, color: _warn),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_error!, style: mono(10, _warn))),
                  ])),
            const SizedBox(height: 20),
            Btn(_busy ? 'CREATING…' : 'CREATE ACCOUNT →', _submit),
            const SizedBox(height: 10),
            Btn('CONTINUE AS GUEST', () => Navigator.pop(c), primary: false),
            const SizedBox(height: 18),
            Center(
                child: GestureDetector(
                    onTap: () => _swapTo(c, const LoginScreen()),
                    child: Text.rich(TextSpan(style: mono(10), children: [
                      const TextSpan(text: 'ALREADY HAVE AN ACCOUNT?  '),
                      TextSpan(text: 'LOG IN', style: mono(10, accent)),
                    ])))),
            const SizedBox(height: 24),
          ])),
      back: true,
      account: false);
}

// ───────────── Profile ─────────────
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileState();
}

class _ProfileState extends State<ProfileScreen> {
  AppUser? _last = Auth.user.value; // keeps content on screen while popping after logout
  static const _months = [
    'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'
  ];
  String _date(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

  Widget _info(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Text(label, style: mono(9)),
        const SizedBox(width: 16),
        Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600))),
      ]));

  void _editName(BuildContext c, AppUser u) {
    final ctrl = TextEditingController(text: u.name);
    showDialog(
        context: c,
        builder: (dctx) => Dialog(
              backgroundColor: card,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Edit name', style: head(18))),
                  const SizedBox(height: 14),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    style: const TextStyle(color: fg, fontSize: 14),
                    decoration: InputDecoration(
                        labelText: 'Full name',
                        labelStyle: mono(9),
                        filled: true,
                        fillColor: bg,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(color: line))),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: Btn('CANCEL', () => Navigator.pop(dctx), primary: false)),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Btn('SAVE', () {
                      if (_vName(ctrl.text) != null) {
                        ScaffoldMessenger.of(dctx).showSnackBar(const SnackBar(
                            content: Text('Enter a name (min 2 characters).')));
                        return;
                      }
                      Auth.rename(ctrl.text);
                      Navigator.pop(dctx);
                      ScaffoldMessenger.of(c)
                          .showSnackBar(const SnackBar(content: Text('Name updated.')));
                    })),
                  ]),
                ])),
              ),
            ));
  }

  @override
  Widget build(BuildContext c) => ValueListenableBuilder<AppUser?>(
      valueListenable: Auth.user,
      builder: (_, v, __) {
        if (v != null) _last = v;
        final u = _last;
        if (u == null) return const Scaffold(body: SizedBox.shrink());
        return frame(
            c,
            'PROFILE',
            ListView(children: [
              const Align(
                  alignment: Alignment.centerLeft, child: Tag('● SIGNED IN', color: teal)),
              const SizedBox(height: 16),
              Row(children: [
                Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFF0955E), accent]),
                      boxShadow: [BoxShadow(color: accent.withAlpha(110), blurRadius: 18)]),
                  child: Text(u.initial,
                      style: const TextStyle(
                          fontSize: 28, fontWeight: FontWeight.w800, color: Colors.black)),
                ),
                const SizedBox(width: 14),
                Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(u.name, style: head(26), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text(u.email, style: mono(10), maxLines: 1, overflow: TextOverflow.ellipsis),
                ])),
              ]),
              const SizedBox(height: 20),
              Panel(
                  stars: false,
                  child: Column(children: [
                    _info('NAME', u.name),
                    _info('EMAIL', u.email),
                    _info('MEMBER SINCE', _date(u.joined)),
                  ])),
              const SizedBox(height: 10),
              Text('Your account is stored with Supabase. Your name is kept in your account profile.',
                  style: mono(9)),
              const SizedBox(height: 20),
              Btn('EDIT NAME', () => _editName(c, u), primary: false),
              const SizedBox(height: 10),
              Btn('LOG OUT', () {
                final messenger = ScaffoldMessenger.of(c);
                Auth.logout();
                Navigator.pop(c);
                messenger.showSnackBar(const SnackBar(content: Text('You have been logged out.')));
              }),
              const SizedBox(height: 24),
            ]),
            back: true,
            account: false);
      });
}