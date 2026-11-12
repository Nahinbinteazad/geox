// Ask GeoX: a grounded question answerer for the bundled results.
//
// Pure Dart (no Flutter imports), so it can be unit tested on its own.
// Every number in an answer is read from geox_data.json at the moment the
// question is asked. Nothing numeric is typed into this file, so the
// companion cannot invent a score. When the data does not hold the answer,
// it says so.

/// One of the stored Moon or Mars targets.
class AskTarget {
  final String id, name, planet;
  const AskTarget(this.id, this.name, this.planet);
}

/// A normalised question: lower case, letters and digits only, single spaces,
/// padded with a space at each end so whole words and phrases can be matched.
class _Q {
  final String text;
  final Set<String> words;
  const _Q._(this.text, this.words);

  factory _Q(String raw) {
    final t = AskGeoX.norm(raw);
    return _Q._(t, t.trim().split(' ').where((w) => w.isNotEmpty).toSet());
  }

  /// 'word' matches a whole word, 'stem*' matches any word starting with stem,
  /// and 'two words' matches that exact phrase.
  bool has(String kw) {
    if (kw.endsWith('*')) {
      final stem = kw.substring(0, kw.length - 1);
      return words.any((w) => w.startsWith(stem));
    }
    if (kw.contains(' ')) return text.contains(' $kw ');
    return words.contains(kw);
  }

  double score(Map<String, double> table) {
    var s = 0.0;
    table.forEach((k, w) {
      if (has(k)) s += w;
    });
    return s;
  }
}

/// How one question was understood: the chosen topic and what it named.
class _Route {
  final String topic;
  final _Q q;
  final String? tid;
  final bool hasTarget;
  final List<Map<String, dynamic>> sites, others;
  final Map<String, dynamic>? city;
  final List<String> regions;
  final String? mission;
  const _Route(this.topic, this.q, this.tid, this.hasTarget, this.sites,
      this.others, this.city, this.regions, this.mission);
}

/// Answers questions from the decoded geox_data.json.
class AskGeoX {
  AskGeoX(Map<String, dynamic> data) : _d = data;

  final Map<String, dynamic> _d;

  // ───────────────────────── small readers ─────────────────────────
  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  static List<Map<String, dynamic>> _maps(Object? v) => v is List
      ? [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)]
      : <Map<String, dynamic>>[];

  static double? _num(Object? v) => v is num ? v.toDouble() : null;

  static String _f(Object? v, [int dp = 1]) {
    final x = _num(v);
    return x == null ? 'not recorded' : x.toStringAsFixed(dp);
  }

  static String _p(Object? v) {
    final x = _num(v);
    if (x == null) return 'not recorded';
    if (x < 0.001) return 'below 0.001';
    return x.toStringAsFixed(3);
  }

  /// Lower case, letters and digits only, single spaces, padded with spaces.
  static String norm(String s) {
    final cleaned = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    return ' ${cleaned.trim().replaceAll(RegExp(r' +'), ' ')} ';
  }

  Map<String, dynamic> get _pipeline => _map(_d['pipeline']);
  Map<String, dynamic> get _summary => _map(_d['validation_summary']);
  Map<String, dynamic> _result(String id) => _map(_map(_d['results'])[id]);

  /// The 20 stored targets, in file order.
  List<AskTarget> get targets => [
        for (final t in _maps(_d['targets']))
          AskTarget('${t['id']}', '${t['name']}', '${t['planet']}')
      ];

  /// The stored target id for a display name such as 'Jezero Crater',
  /// or null for a custom point.
  String? idForName(String? name) {
    if (name == null) return null;
    final n = norm(name);
    for (final t in targets) {
      if (norm(t.name) == n) return t.id;
    }
    return null;
  }

  String _targetName(String? id) {
    for (final t in targets) {
      if (t.id == id) return t.name;
    }
    return id ?? 'this target';
  }

  Map<String, dynamic> _target(String id) {
    for (final t in _maps(_d['targets'])) {
      if (t['id'] == id) return t;
    }
    return <String, dynamic>{};
  }

  Map<String, Map<String, dynamic>>? _siteCache;
  Map<String, Map<String, dynamic>> get _sites => _siteCache ??= {
        for (final s in _maps(_d['sites'])) '${s['id']}': s
      };
  final Map<String, List<Map<String, dynamic>>> _rankCache = {};

  /// The name the app shows for a site (same rule as BundledData.rankingFor).
  static String _siteName(Map<String, dynamic> s) =>
      '${s['raw_name'] ?? s['name'] ?? s['id'] ?? 'Unnamed site'}';

  /// Ranked rows for a target, each joined with its site record under 'site'.
  List<Map<String, dynamic>> _ranked(String id) =>
      _rankCache[id] ??= _buildRanked(id);

  List<Map<String, dynamic>> _buildRanked(String id) {
    final sites = _sites;
    final out = <Map<String, dynamic>>[];
    for (final r in _maps(_result(id)['ranked'])) {
      final s = sites['${r['site_id']}'];
      if (s == null) continue;
      out.add({...r, 'site': s});
    }
    out.sort((a, b) => (_num(a['rank']) ?? 1e9).compareTo(_num(b['rank']) ?? 1e9));
    return out;
  }

  // ───────────────────────── vocabulary ─────────────────────────
  static const _missionLabels = {
    'rover': 'rover mobility',
    'geology': 'geology',
    'astrobiology': 'astrobiology',
    'eva': 'EVA (astronaut walks)',
    'isru': 'ISRU (using local resources)',
  };

  /// Which features each mission lens averages (same as MISSION_LENS in the notebook).
  static const _missionFeatures = {
    'rover': 'slope and surface roughness',
    'geology': 'bare ground and surface roughness',
    'astrobiology': 'dryness, vegetation and surface temperature',
    'eva': 'surface temperature, day to night swing and slope',
    'isru': 'bare ground, dryness and surface temperature',
  };

  static const _missionWords = {
    'rover': ['rover*', 'mobility', 'drive', 'driving', 'wheel*', 'traverse*'],
    'geology': ['geolog*', 'rock*', 'mineral*'],
    'astrobiology': [
      'astrobiolog*', 'life', 'biolog*', 'microb*', 'biosignature*', 'habitab*',
    ],
    'eva': ['eva', 'spacewalk*', 'astronaut*', 'walk', 'walking', 'spacesuit*', 'crew'],
    'isru': ['isru', 'resource*', 'mining', 'extract*'],
  };

  static const _featureNames = {
    'slope': 'slope',
    'roughness': 'surface roughness',
    'temperature': 'surface temperature',
    'temperature_variation': 'day to night swing',
    'ndvi': 'vegetation (NDVI)',
    'bare_ground': 'bare ground',
    'elevation': 'elevation',
    'aridity': 'dryness',
  };

  // Keyword tables. A question is scored against every table and the highest
  // score wins, so one stray word cannot hijack the answer.
  static const _kTop = {
    'top': 1.5, 'best': 1.0, 'first': 1.5, 'rank*': 1.0, 'number one': 1.5,
    'leading': 1.0, 'highest': 1.0, 'closest': 1.0, 'most similar': 1.5,
    'list': 1.0, 'which sites': 1.0, 'winner': 1.0,
  };
  static const _kAccuracy = {
    'accura*': 2.0, 'validat*': 2.0, 'trust*': 2.0, 'reliab*': 2.0,
    'benchmark*': 2.0, 'proof': 2.0, 'prove*': 2.0, 'evidence': 2.0,
    'correct': 1.5, 'sure': 1.0, 'confiden*': 1.5, 'control*': 1.0,
    'does it work': 2.0, 'does this work': 2.0, 'p value': 1.0,
  };
  static const _kMethod = {
    'how': 0.5, 'calculat*': 2.0, 'comput*': 2.0, 'method*': 2.0,
    'formula': 2.0, 'algorithm*': 2.0, 'score*': 1.0, 'work*': 1.0,
    'scal*': 1.0, 'model': 1.0, 'how does it work': 3.0, 'how it works': 3.0,
    'explain': 0.5, 'measure*': 0.5,
  };
  static const _kTrend = {
    'trend*': 3.0, 'chang*': 2.0, 'year*': 1.5, 'over time': 2.0,
    'decade*': 1.5, 'drift*': 2.0, 'becoming': 2.0, 'mars like': 1.0,
    'moon like': 1.0, 'sen': 1.5, 'mann': 1.5, 'kendall': 1.5,
    'climate': 1.0, 'warming': 1.5, 'history': 1.0, 'getting': 1.0,
  };
  static const _kLimits = {
    'gravity': 3.0, 'radiation': 3.0, 'atmospher*': 2.0, 'pressure': 2.0,
    'vacuum': 2.0, 'oxygen': 2.0, 'air': 1.0, 'cannot': 2.0, 'can t': 2.0,
    'limit*': 2.0, 'reproduc*': 2.0, 'equivalen*': 2.0, 'identical': 2.0,
    'exactly': 1.0, 'same as': 1.5, 'unmatched': 2.0, 'weakness*': 2.0,
    'downside*': 2.0, 'caveat*': 2.0,
  };
  static const _kSources = {
    'data': 1.0, 'dataset*': 2.0, 'source*': 2.0, 'modis': 3.0,
    'copernicus': 3.0, 'sentinel*': 3.0, 'worldcover': 3.0,
    'aridity index': 3.0, 'trek*': 2.0, 'nasa': 1.0, 'come from': 2.0,
    'comes from': 2.0, 'where': 0.5,
  };
  static const _kVisualOff = {
    'no picture': 3.0, 'no image': 3.0, 'no photo': 3.0, 'no tile': 3.0,
    'without picture': 3.0, 'without image': 3.0, 'without a picture': 3.0,
    'without an image': 3.0, 'missing picture': 3.0, 'missing image': 3.0,
    'shadow*': 2.0, 'dark': 1.5, 'flat': 1.5, 'blank': 2.0,
    'picture': 0.5, 'image*': 0.5, 'photo*': 0.5, 'tile*': 1.0,
  };
  static const _kFusion = {
    'visual': 2.0, 'picture*': 1.0, 'image*': 1.0, 'photo*': 1.0,
    'satellite': 1.0, 'environment*': 1.0, 'fusion': 2.0, 'fuse*': 2.0,
    'blend*': 2.0, 'weight*': 1.5, 'dinov2': 3.0, 'vision': 2.0,
    'ablation': 3.0, 'look*': 0.5,
  };
  static const _kCity = {
    'city': 3.0, 'cities': 3.0, 'town': 2.0, 'my home': 2.0,
    'where i live': 3.0, 'hometown': 3.0, 'reverse': 3.0, 'my location': 2.0,
  };
  static const _kKnown = {
    'known': 2.0, 'documented': 2.0, 'already used': 2.0, 'existing': 1.0,
    'famous': 1.5, 'analog*': 0.5, 'used by nasa': 2.0,
  };
  static const _kTargetInfo = {
    'tell me about': 2.0, 'describe': 2.0, 'what is': 0.5, 'about': 0.5,
    'temperature': 1.0, 'cold': 1.5, 'hot': 1.5, 'rough*': 1.0, 'slope': 1.0,
    'steep': 1.0, 'vegetation': 1.0, 'ndvi': 1.0, 'bare': 1.0,
    'conditions': 1.5, 'like there': 1.5, 'feature*': 1.0, 'value*': 1.0,
  };
  static const _kHelp = {
    'hello': 3.0, 'hi': 3.0, 'hey': 3.0, 'help': 2.0, 'what can you': 3.0,
    'what can i ask': 3.0, 'who are you': 3.0, 'what are you': 2.0,
    'thank*': 3.0,
  };
  static const _kCompare = {
    'compare*': 2.0, 'comparison': 2.0, 'vs': 2.0, 'versus': 2.0,
    'difference*': 2.0, 'different': 1.0, 'better': 1.0,
  };

  /// Words in target names that are too common to identify a target alone.
  static const _generic = {
    'crater', 'planitia', 'planum', 'mons', 'valley', 'pit', 'rim', 'massif',
    'ridge', 'mensae', 'pole', 'lunar', 'mare', 'south', 'north',
  };

  /// Words in site names too common to identify a site alone.
  static const _siteStop = {
    'mars', 'moon', 'lunar', 'desert', 'death', 'polar', 'site', 'grid',
    'other', 'crater', 'mount', 'lake', 'valley', 'island', 'islands',
  };

  // ───────────────────────── entity finders ─────────────────────────

  /// A stored target named in the question, if any.
  String? _targetIn(_Q q) {
    for (final t in targets) {
      final full = norm(t.name).trim();
      if (q.has(full)) return t.id;
      final short = full.split(' ').where((w) => !_generic.contains(w)).join(' ');
      if (short.length >= 4 && q.has(short)) return t.id;
    }
    if (q.has('south pole')) return idForName('Lunar South Pole');
    return null;
  }

  /// Phrases that identify a site: its full names, and for named places the
  /// part before a comma or bracket and a distinctive first word.
  static List<String> _siteAliases(Map<String, dynamic> s) {
    final out = <String>{};
    for (final raw in ['${s['raw_name'] ?? ''}', '${s['name'] ?? ''}']) {
      final full = norm(raw).trim();
      if (full.isEmpty) continue;
      out.add(full);
      if (full.contains('grid site')) continue;
      final head = norm(raw.split(RegExp(r'[(,]')).first).trim();
      if (head.isNotEmpty) out.add(head);
      final headWords = head.split(' ');
      final first = headWords.first;
      if (first.length >= 5 && !_siteStop.contains(first)) out.add(first);
      // 'Mars Desert Research Station' is also known as 'mdrs'.
      if (headWords.length >= 3) out.add(headWords.map((w) => w[0]).join());
    }
    return out.toList();
  }

  /// Ranked rows (for [id]) whose site is named in the question, best rank
  /// first, at most one row per distinct site name.
  List<Map<String, dynamic>> _sitesIn(_Q q, String id) {
    final found = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final r in _ranked(id)) {
      final s = _map(r['site']);
      final name = _siteName(s);
      if (seen.contains(name)) continue;
      if (_siteAliases(s).any(q.has)) {
        seen.add(name);
        found.add(r);
      }
    }
    return found;
  }

  /// Stored sites named in the question that are not in [id]'s ranking.
  List<Map<String, dynamic>> _otherSitesIn(_Q q, String id) {
    final inRanking = {for (final r in _ranked(id)) '${r['site_id']}'};
    // Grid sites share names, so a name already in this ranking means that one.
    final names = {for (final r in _ranked(id)) _siteName(_map(r['site']))};
    final out = <Map<String, dynamic>>[];
    for (final s in _sites.values) {
      if (inRanking.contains('${s['id']}')) continue;
      final name = _siteName(s);
      if (names.contains(name)) continue;
      if (_siteAliases(s).any(q.has)) {
        names.add(name);
        out.add(s);
      }
    }
    return out;
  }

  Map<String, dynamic>? _cityIn(_Q q) {
    for (final r in _maps(_d['reverse'])) {
      final label = norm('${r['label'] ?? ''}').trim();
      if (label.isNotEmpty && q.has(label)) return r;
    }
    return null;
  }

  /// Regions (countries) named in the question that appear in [id]'s ranking.
  List<String> _regionsIn(_Q q, String id) {
    final regions = <String>{};
    for (final r in _ranked(id)) {
      final region = '${_map(r['site'])['region'] ?? ''}';
      if (region.isNotEmpty) regions.add(region);
    }
    final hits = <String>[];
    for (final region in regions) {
      final full = norm(region).trim();
      final head = norm(region.split('(').first).trim();
      final inside = region.contains('(')
          ? norm(region.split('(').last.replaceAll(')', '')).trim()
          : '';
      final aliases = {
        full,
        head,
        if (inside.length >= 5) inside,
        if (head == 'united states') ...['usa', 'america'],
      };
      if (aliases.any((a) => a.isNotEmpty && q.has(a))) hits.add(region);
    }
    return hits;
  }

  String? _missionIn(_Q q) {
    for (final e in _missionWords.entries) {
      if (e.value.any(q.has)) return e.key;
    }
    return null;
  }

  int? _numberIn(_Q q) {
    for (final w in q.words) {
      final n = int.tryParse(w);
      if (n != null && n >= 1 && n <= 50) return n;
    }
    return null;
  }

  // ───────────────────────── public API ─────────────────────────

  /// Ready-made questions for the chips on the Ask GeoX page. Each one is
  /// answered from the data (checked by test/ask_geox_test.dart).
  List<String> suggestions(String? targetId) {
    final cities = _maps(_d['reverse']);
    final city = cities.isEmpty ? null : '${cities.first['label']}';
    if (targetId == null) {
      return [
        'How does the score work?',
        if (city != null) 'How Mars-like is $city?',
        'What can Earth not reproduce?',
        'Where does the data come from?',
      ];
    }
    final name = _targetName(targetId);
    final ranked = _ranked(targetId);
    final visualOn = _target(targetId)['visual_scoring'] == true;
    return [
      if (ranked.isNotEmpty)
        'Why does ${_siteName(_map(ranked.first['site']))} rank first?',
      'How accurate is this?',
      'Is the best site becoming more like $name?',
      'Which site is best for a rover?',
      visualOn
          ? 'How much does the satellite picture count?'
          : 'Why is there no picture for $name?',
      if (city != null) 'How Mars-like is $city?',
      'What can Earth not reproduce?',
    ];
  }

  /// The topic a question is routed to ('site', 'trend', 'city', ...), or ''
  /// when nothing matched. Used by the tests.
  String topic(String? targetId, String question) =>
      _route(targetId, question).topic;

  _Route _route(String? targetId, String question) {
    final q = _Q(question);
    if (q.words.isEmpty) {
      return _Route('empty', q, targetId, false, const [], const [], null,
          const [], null);
    }

    final named = _targetIn(q);
    final tid = named ?? targetId;
    final hasTarget = tid != null && _result(tid).isNotEmpty;

    final sites = hasTarget ? _sitesIn(q, tid) : <Map<String, dynamic>>[];
    final others = hasTarget ? _otherSitesIn(q, tid) : <Map<String, dynamic>>[];
    final city = _cityIn(q);
    final regions = hasTarget ? _regionsIn(q, tid) : <String>[];
    final mission = _missionIn(q);

    // Score every intent. Entities (a named site, city, country or mission)
    // carry a strong base score; keywords add to it.
    final compareWords = q.score(_kCompare);
    final scores = <String, double>{
      'compare': sites.length >= 2 || (sites.length == 1 && others.isNotEmpty)
          ? 5.0
          : (sites.length == 1 && compareWords > 0 ? 4.0 : 0.0),
      'site': sites.length == 1 ? 3.5 : (others.isNotEmpty ? 3.0 : 0.0),
      'city': city != null ? 4.0 : q.score(_kCity),
      'mission': mission != null ? 3.0 : 0.0,
      'region': regions.isNotEmpty ? 2.5 : 0.0,
      'trend': q.score(_kTrend),
      'visualoff': q.score(_kVisualOff),
      'accuracy': q.score(_kAccuracy),
      'fusion': q.score(_kFusion),
      'method': q.score(_kMethod),
      'limits': q.score(_kLimits),
      'sources': q.score(_kSources),
      'known': q.score(_kKnown),
      'top': q.score(_kTop),
      'targetinfo': q.score(_kTargetInfo),
      'help': q.score(_kHelp),
    };
    // Earlier in this list wins a tie.
    const order = [
      'compare', 'site', 'city', 'mission', 'region', 'trend', 'visualoff',
      'accuracy', 'fusion', 'method', 'limits', 'sources', 'known', 'top',
      'targetinfo', 'help',
    ];
    var best = '';
    var bestScore = 0.0;
    for (final k in order) {
      final s = scores[k] ?? 0;
      if (s > bestScore) {
        best = k;
        bestScore = s;
      }
    }
    return _Route(best, q, tid, hasTarget, sites, others, city, regions, mission);
  }

  /// The answer to [question], about the target [targetId] (null for a custom
  /// point). A target named inside the question takes over from [targetId].
  String answer(String? targetId, String question) {
    final r = _route(targetId, question);
    final best = r.topic;
    final q = r.q;
    final tid = r.tid;
    final hasTarget = r.hasTarget;
    final sites = r.sites;
    final others = r.others;
    final city = r.city;
    final regions = r.regions;
    final mission = r.mission;
    if (best == 'empty') return 'Type a question, or tap one of the examples.';
    if (best.isEmpty) return _fallback(tid);

    // These need a stored target. A custom point has no stored results.
    const needsTarget = {
      'compare', 'site', 'mission', 'region', 'trend', 'visualoff', 'known',
      'top', 'targetinfo',
    };
    if (!hasTarget && needsTarget.contains(best)) return _customNote();

    switch (best) {
      case 'compare':
        if (sites.length >= 2) return _compare(tid!, sites[0], sites[1]);
        if (others.isNotEmpty) {
          // One named site is in this ranking and the other is not, so a
          // side-by-side comparison would be misleading.
          return '${_site(tid!, sites.first)} ${_siteElsewhere(tid!, others.first)}';
        }
        return _compareWithNeighbour(tid!, sites.first);
      case 'site':
        return sites.length == 1
            ? _site(tid!, sites.first)
            : others.take(2).map((s) => _siteElsewhere(tid!, s)).join(' ');
      case 'city':
        return city != null ? _city(city, hasTarget ? tid : null) : _cities();
      case 'mission':
        return _mission(tid!, mission!);
      case 'region':
        return _region(tid!, regions);
      case 'trend':
        return _trend(tid!);
      case 'visualoff':
        return _visual(tid!);
      case 'accuracy':
        return hasTarget ? _accuracy(tid!) : _accuracySummary();
      case 'fusion':
        return _fusion(hasTarget ? tid : null);
      case 'method':
        return _method(hasTarget ? tid : null);
      case 'limits':
        return _limits();
      case 'sources':
        return _sources(hasTarget ? tid : null);
      case 'known':
        return _known(tid!);
      case 'top':
        final n = _numberIn(q);
        final wantsList = n != null ||
            q.has('list') ||
            q.has('sites') ||
            q.has('top');
        return wantsList ? _topList(tid!, n ?? 5) : _whyFirst(tid!);
      case 'targetinfo':
        return _targetInfo(tid!);
      case 'help':
        return q.has('thank*')
            ? 'You are welcome. Ask another question whenever you like.'
            : _help(tid);
    }
    return _fallback(tid);
  }

  // ───────────────────────── answer builders ─────────────────────────

  String _customNote() =>
      'This page is answering for a custom point. Stored answers exist only '
      'for the ${targets.length} standard targets, because a custom point is '
      'scored live and nothing about it is saved. Pick a target from the list '
      'at the top to ask about it.';

  String _fallback(String? tid) =>
      'I can only answer from the values stored in the app, and I could not '
      'match that question to them. ${_examples(tid)}';

  String _help(String? tid) =>
      'I am Ask GeoX. I answer questions using only the results stored in '
      'this app, and I say so when the data does not hold the answer. '
      '${_examples(tid)}';

  String _examples(String? tid) {
    final s = suggestions(tid).take(3).map((e) => '"$e"').join(', ');
    return 'You can ask about a site by name, the top sites, a mission '
        '(rover, geology, astrobiology, EVA, ISRU), trends, accuracy, the '
        'satellite pictures, the data sources, or a city. For example: $s.';
  }

  String _site(String tid, Map<String, dynamic> r) {
    final s = _map(r['site']);
    final name = _siteName(s);
    final total = _ranked(tid).length;
    final b = StringBuffer();
    b.write('$name is ranked ${_f(r['rank'], 0)} of the $total stored results '
        'for ${_targetName(tid)}, with an overall score of '
        '${_f(r['fusion_score'])}. ');
    b.write('That comes from ${_f(r['environmental_score'])} on measured '
        'environment');
    final vis = _num(r['visual_score']);
    if (vis == null) {
      b.write(' and no picture score, because this target has no usable '
          'picture. ');
    } else {
      b.write(' and ${vis.toStringAsFixed(1)} on how the landscape looks');
      b.write(r['visual_reliable'] == false
          ? ' (a low-confidence picture score). '
          : '. ');
    }
    final strong = [for (final x in (r['strong_matches'] as List? ?? const [])) '$x'];
    final weak = [for (final x in (r['weak_matches'] as List? ?? const [])) '$x'];
    if (strong.isNotEmpty) b.write('Close matches: ${strong.join(', ')}. ');
    if (weak.isNotEmpty) b.write('Poor matches: ${weak.join(', ')}. ');
    final m = _map(r['mission_relevance']);
    String? bestLens;
    double bestVal = -1;
    m.forEach((k, v) {
      final x = _num(v);
      if (x != null && x > bestVal) {
        bestVal = x;
        bestLens = k;
      }
    });
    if (bestLens != null) {
      b.write('Its strongest mission use is ${_missionLabels[bestLens] ?? bestLens} '
          '(${bestVal.toStringAsFixed(1)}). ');
    }
    final region = '${s['region'] ?? ''}';
    b.write(s['known_analogue'] == true
        ? 'It is already a documented analogue site'
        : 'It is a candidate, not yet a documented analogue');
    b.write(region.isEmpty
        ? '.'
        : ', in $region (${_f(s['lat'], 2)}, ${_f(s['lon'], 2)}).');
    return b.toString();
  }

  String _siteElsewhere(String tid, Map<String, dynamic> s) {
    final name = _siteName(s);
    final where = <String>[];
    for (final t in targets) {
      for (final r in _ranked(t.id)) {
        if (r['site_id'] == s['id']) {
          where.add('${t.name} (rank ${_f(r['rank'], 0)})');
          break;
        }
      }
    }
    final top = _ranked(tid).length;
    final tail = where.isEmpty
        ? 'It is not in any stored ranking.'
        : 'It does appear for ${where.join(', ')}.';
    return '$name is not among the $top stored results for '
        '${_targetName(tid)}. $tail';
  }

  String _compare(String tid, Map<String, dynamic> a, Map<String, dynamic> b) {
    final na = _siteName(_map(a['site']));
    final nb = _siteName(_map(b['site']));
    if (na == nb) return _site(tid, a);
    final fa = _num(a['fusion_score']) ?? 0;
    final fb = _num(b['fusion_score']) ?? 0;
    final lead = fa >= fb ? na : nb;
    final buf = StringBuffer(
        'For ${_targetName(tid)}: $na is rank ${_f(a['rank'], 0)} with '
        '${_f(a['fusion_score'])}, and $nb is rank ${_f(b['rank'], 0)} with '
        '${_f(b['fusion_score'])}. $lead is ahead by '
        '${(fa - fb).abs().toStringAsFixed(1)} points. ');
    final pa = _map(a['fingerprint']);
    final pb = _map(b['fingerprint']);
    String? axis;
    var gap = -1.0;
    pa.forEach((k, v) {
      final x = _num(v);
      final y = _num(pb[k]);
      if (x != null && y != null && (x - y).abs() > gap) {
        gap = (x - y).abs();
        axis = k;
      }
    });
    if (axis != null) {
      buf.write('The biggest difference is ${axis!.replaceAll('_', ' ')}: '
          '${_f(pa[axis])} against ${_f(pb[axis])}.');
    }
    return buf.toString();
  }

  String _compareWithNeighbour(String tid, Map<String, dynamic> r) {
    final ranked = _ranked(tid);
    final i = ranked.indexWhere((x) => x['site_id'] == r['site_id']);
    if (ranked.length < 2 || i < 0) return _site(tid, r);
    final other = i == 0 ? ranked[1] : ranked[0];
    return _compare(tid, r, other);
  }

  String _whyFirst(String tid) {
    final ranked = _ranked(tid);
    if (ranked.isEmpty) return 'No ranked sites are stored for ${_targetName(tid)}.';
    final first = ranked.first;
    final b = StringBuffer(_site(tid, first));
    if (ranked.length > 1) {
      final second = ranked[1];
      final gap = (_num(first['fusion_score']) ?? 0) -
          (_num(second['fusion_score']) ?? 0);
      b.write(' Second place is ${_siteName(_map(second['site']))} with '
          '${_f(second['fusion_score'])}, ${gap.toStringAsFixed(1)} points behind.');
    }
    return b.toString();
  }

  String _topList(String tid, int n) {
    final ranked = _ranked(tid);
    if (ranked.isEmpty) return 'No ranked sites are stored for ${_targetName(tid)}.';
    final k = n.clamp(1, ranked.length).toInt();
    final lines = [
      for (final r in ranked.take(k))
        '${_f(r['rank'], 0)}. ${_siteName(_map(r['site']))}, score '
            '${_f(r['fusion_score'])}'
            '${_map(r['site'])['known_analogue'] == true ? ' (documented analogue)' : ''}'
    ];
    final more = n > ranked.length
        ? '\nOnly ${ranked.length} results are stored for this target.'
        : '';
    return 'Top $k for ${_targetName(tid)}:\n${lines.join('\n')}$more';
  }

  String _mission(String tid, String lens) {
    final rows = [
      for (final r in _ranked(tid))
        if (_num(_map(r['mission_relevance'])[lens]) != null) r
    ]..sort((a, b) => (_num(_map(b['mission_relevance'])[lens]) ?? 0)
        .compareTo(_num(_map(a['mission_relevance'])[lens]) ?? 0));
    final label = _missionLabels[lens] ?? lens;
    if (rows.isEmpty) {
      return 'No stored site has a $label score for ${_targetName(tid)}.';
    }
    final top = rows.take(3).toList();
    final names = [
      for (final r in top)
        '${_siteName(_map(r['site']))} (${_f(_map(r['mission_relevance'])[lens])})'
    ];
    return 'For $label at ${_targetName(tid)}, the best stored site is '
        '${names.first}${names.length > 1 ? ', then ${names.skip(1).join(', then ')}' : ''}. '
        'This mission score is the average similarity of '
        '${_missionFeatures[lens] ?? 'the features that matter for this job'}, '
        'so it can differ from the overall rank.';
  }

  String _region(String tid, List<String> regions) {
    final rows = [
      for (final r in _ranked(tid))
        if (regions.contains('${_map(r['site'])['region']}')) r
    ];
    final where = regions.join(' and ');
    if (rows.isEmpty) {
      return 'No site in $where is among the stored results for ${_targetName(tid)}.';
    }
    final lines = [
      for (final r in rows.take(8))
        '${_siteName(_map(r['site']))}, rank ${_f(r['rank'], 0)}, score '
            '${_f(r['fusion_score'])}'
    ];
    return '${rows.length} stored result${rows.length == 1 ? '' : 's'} for '
        '${_targetName(tid)} ${rows.length == 1 ? 'is' : 'are'} in $where:\n'
        '${lines.join('\n')}';
  }

  String _trend(String tid) {
    final t = _map(_result(tid)['trend']);
    final name = _targetName(tid);
    if (t.isEmpty) return 'There is no trend stored for $name.';
    final years = [for (final y in (t['years'] as List? ?? const [])) _num(y)];
    final sim = [for (final v in (t['similarity'] as List? ?? const [])) _num(v)];
    final slope = _num(t['sen_slope_per_year']) ?? 0;
    final sig = t['significant'] == true;
    final b = StringBuffer();
    b.write('GeoX tracks the best-matching site, '
        '${t['site_name'] ?? 'the top site'}, for $name');
    if (years.isNotEmpty && years.first != null && years.last != null) {
      b.write(' from ${years.first!.toStringAsFixed(0)} to '
          '${years.last!.toStringAsFixed(0)}');
    }
    b.write('. It measures the change with Sen\'s slope and checks whether it '
        'is real with the Mann-Kendall test. The slope is '
        '${slope.toStringAsFixed(4)} points a year and the p value is '
        '${_p(t['mann_kendall_p'])}. ');
    if (sim.length >= 2 && sim.first != null && sim.last != null) {
      final change = sim.last! - sim.first!;
      b.write('From the first year to the last, the similarity moved by '
          '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)} points. ');
    }
    b.write(sig
        ? 'This trend is statistically significant: the site is slowly becoming '
            '${slope < 0 ? 'less' : 'more'} like $name. '
        : 'This is not statistically significant, so GeoX does not claim a trend. ');
    var count = 0, total = 0;
    final results = _map(_d['results']);
    for (final r in results.values) {
      final tr = _map(_map(r)['trend']);
      if (tr.isEmpty) continue;
      total++;
      if (tr['significant'] == true) count++;
    }
    b.write('Across all targets, $count of $total show a significant trend.');
    return b.toString();
  }

  String _visual(String tid) {
    final t = _target(tid);
    final name = _targetName(tid);
    final scoring = _map(_result(tid)['scoring']);
    final off = [
      for (final x in _maps(_d['targets']))
        if (x['visual_scoring'] != true) '${x['name']}'
    ];
    if (t['visual_scoring'] != true || scoring['visual_used'] == false) {
      final reason = scoring['visual_off_reason'] ?? t['visual_off_reason'];
      return '$name has no usable picture score'
          '${reason == null ? '' : ': $reason'}. Instead of pretending to see, '
          'GeoX scores it on the measured environment alone. '
          '${off.length} of ${targets.length} targets are in this situation: '
          '${off.join(', ')}.';
    }
    final tile = _map(t['tile']);
    final src = '${tile['source'] ?? ''}'.split(' · ').first;
    return '$name has a usable picture'
        '${src.isEmpty ? '' : ' ($src from NASA Trek'}'
        '${tile['m_per_px'] == null ? '' : ', ${_f(tile['m_per_px'], 0)} m per pixel'}'
        '${src.isEmpty ? '' : ')'}, so it gets a picture score. '
        '${off.isEmpty ? '' : 'The targets without one are ${off.join(', ')}.'}';
  }

  String _accuracy(String tid) {
    final v = _map(_result(tid)['validation']);
    final name = _targetName(tid);
    if (v.isEmpty) return 'No validation is stored for $name. ${_accuracySummary()}';
    if (v['benchmark_applies'] != true) {
      return 'The check does not apply to $name: '
          '${v['benchmark_scope_note'] ?? 'it is outside the benchmark'}. '
          '${_accuracySummary()}';
    }
    return 'For $name, the documented analogue sites average '
        '${_f(v['known_mean_score'])} against ${_f(v['control_mean_score'])} '
        'for the control sites (higher is better). Their average rank among the '
        '${_pipeline['earth_sites_analysed'] ?? ''} Earth sites is '
        '${_f(v['known_mean_rank'], 0)} against ${_f(v['control_mean_rank'], 0)}, '
        'and the p value is ${_p(v['p_value'])}. ${_accuracySummary()}';
  }

  String _accuracySummary() {
    final s = _summary;
    if (s.isEmpty) return '';
    final b = StringBuffer(
        'Across the run, ${s['targets_with_significant_separation']} of '
        '${s['targets_in_scope']} targets in scope separate the '
        '${s['known_analogues']} known analogues from the ${s['controls']} controls.');
    final outIds = s['targets_out_of_scope'] as List? ?? const [];
    final out = [for (final x in outIds) _targetName('$x')];
    if (out.isNotEmpty) b.write(' Out of scope: ${out.join(', ')}.');
    if (s['honest_note'] != null) b.write(' ${s['honest_note']}');
    return b.toString();
  }

  String _fusion(String? tid) {
    final p = _pipeline;
    final w = _map(p['fusion_weights']);
    final env = (_num(w['environmental']) ?? 0) * 100;
    final vis = (_num(w['visual']) ?? 0) * 100;
    final b = StringBuffer(
        'The overall score blends ${env.toStringAsFixed(0)}% measured environment '
        'with ${vis.toStringAsFixed(0)}% picture similarity from '
        '${p['vision_encoder'] ?? 'a vision model'}. ');
    if (tid != null) {
      final sc = _map(_result(tid)['scoring']);
      if (sc['visual_used'] == false) {
        b.write('${_targetName(tid)} has no usable picture, so it uses the '
            'environment alone. ');
      }
      final ab = _map(_map(_summary['ablation_sample'])[tid]);
      if (ab.isNotEmpty) {
        String gap(String k) => _f(_map(ab[k])['gap']);
        b.write('For ${_targetName(tid)}, known analogues beat the controls by '
            '${gap('environment only')} points with environment only, '
            '${gap('visual only')} with pictures only, and ${gap('fusion')} '
            'with the blend. ');
      }
    }
    if (_summary['honest_note'] != null) b.write('${_summary['honest_note']}');
    return b.toString().trim();
  }

  String _method(String? tid) {
    final p = _pipeline;
    final w = _map(p['fusion_weights']);
    final used = tid == null
        ? const []
        : (_map(_result(tid)['scoring'])['features_used'] as List? ?? const []);
    final feats = [for (final f in used) _featureNames['$f'] ?? '$f'];
    final b = StringBuffer();
    b.write('GeoX searched ${p['earth_sites_analysed'] ?? 'the'} Earth sites '
        'against ${p['targets_analysed'] ?? targets.length} targets. ');
    if (feats.isNotEmpty) {
      b.write('For ${_targetName(tid)} it compares ${feats.length} measured '
          'features: ${feats.join(', ')}. ');
    }
    b.write('Each feature is put on a shared scale (${p['scaler'] ?? 'robust'} '
        'scaler), and every Earth site gets an environment score for how close '
        'its values are to the target. Where the target has a usable picture, a '
        'picture score from ${p['vision_encoder'] ?? 'a vision model'} is added, '
        '${((_num(w['environmental']) ?? 0) * 100).toStringAsFixed(0)}% '
        'environment and ${((_num(w['visual']) ?? 0) * 100).toStringAsFixed(0)}% '
        'picture. ');
    for (final n in (p['notes'] as List? ?? const []).take(2)) {
      b.write('$n ');
    }
    return b.toString().trim();
  }

  String _limits() {
    final d = _pipeline['disclaimer'];
    return 'No place on Earth reproduces another world. Gravity, air pressure, '
        'radiation, vacuum and the make-up of the air are all different, and '
        'GeoX does not claim otherwise. It compares terrain, temperature, '
        'vegetation and bare ground, which is what a field test on Earth can '
        'stand in for.${d == null ? '' : ' $d'}';
  }

  String _sources(String? tid) {
    final p = _pipeline;
    final src = [for (final s in (p['data_sources'] as List? ?? const [])) '$s'];
    final b = StringBuffer(src.isEmpty
        ? 'The data sources are not listed in the stored file. '
        : 'The data comes from ${src.join(', ')}. ');
    if (p['vision_encoder'] != null) {
      b.write('Pictures are compared with ${p['vision_encoder']}. ');
    }
    if (tid != null) {
      final tile = _map(_target(tid)['tile']);
      final s = '${tile['source'] ?? ''}'.split(' · ').first;
      if (s.isNotEmpty) {
        b.write('The ${_targetName(tid)} picture is $s from NASA Trek'
            '${tile['m_per_px'] == null ? '' : ', at ${_f(tile['m_per_px'], 0)} m per pixel'}. ');
      }
    }
    return b.toString().trim();
  }

  String _known(String tid) {
    final rows = [
      for (final r in _ranked(tid))
        if (_map(r['site'])['known_analogue'] == true) r
    ];
    final s = _summary;
    final bench = s.isEmpty
        ? ''
        : ' The accuracy check uses ${s['known_analogues']} documented '
            'analogues and ${s['controls']} control sites.';
    if (rows.isEmpty) {
      return 'No documented analogue site is in the stored top '
          '${_ranked(tid).length} for ${_targetName(tid)}.$bench';
    }
    final names = [
      for (final r in rows)
        '${_siteName(_map(r['site']))} (rank ${_f(r['rank'], 0)})'
    ];
    return 'Documented analogue sites in the stored results for '
        '${_targetName(tid)}: ${names.join(', ')}.$bench';
  }

  String _targetInfo(String tid) {
    final t = _target(tid);
    final name = _targetName(tid);
    final f = _map(t['features']);
    final conf = _map(t['value_confidence']);
    String one(String key, String label, String unit, [int dp = 1]) {
      final v = _num(f[key]);
      if (v == null) return '';
      final c = conf[key] == null ? '' : ', ${conf[key]}';
      return '$label ${v.toStringAsFixed(dp)}$unit$c';
    }

    final parts = [
      one('temperature', 'surface temperature', ' °C'),
      one('temperature_variation', 'day to night swing', ' °C'),
      one('slope', 'slope', '°'),
      one('roughness', 'roughness', ' m'),
      one('ndvi', 'vegetation (NDVI)', '', 2),
      one('bare_ground', 'bare ground', '', 2),
    ].where((x) => x.isNotEmpty).toList();
    final planet = '${t['planet'] ?? ''}';
    final desc = '${t['description'] ?? ''}';
    final b = StringBuffer('$name is on '
        '${planet.toLowerCase() == 'moon' ? 'the Moon' : 'Mars'}');
    b.write(desc.isEmpty ? '. ' : ': $desc. ');
    if (parts.isNotEmpty) b.write('Stored values: ${parts.join('; ')}. ');
    b.write('Elevation and dryness are not compared for other worlds.');
    return b.toString();
  }

  String _city(Map<String, dynamic> r, String? tid) {
    final label = '${r['label']}';
    final m = _map(r['best_mars']);
    final o = _map(r['best_moon']);
    final b = StringBuffer(
        '$label is ${r['verdict'] ?? 'scored'}. Its environment is closer to '
        'its best-matching target than ${_f(r['earth_percentile'])}% of the '
        '${_pipeline['earth_sites_analysed'] ?? ''} Earth sites searched. ');
    if (m.isNotEmpty) {
      b.write('Closest Mars target: ${_targetName('${m['target_id']}')} '
          '(environment score ${_f(m['environmental_score'])}). ');
    }
    if (o.isNotEmpty) {
      b.write('Closest Moon target: ${_targetName('${o['target_id']}')} '
          '(environment score ${_f(o['environmental_score'])}). ');
    }
    if (tid != null) {
      final s = _map(_map(r['scores'])[tid]);
      if (s.isNotEmpty) {
        b.write('For ${_targetName(tid)} its environment score is '
            '${_f(s['environmental_score'])}, higher than '
            '${_f(s['percentile_vs_earth_sites'])}% of the Earth sites. ');
      }
    }
    if (r['note'] != null) b.write('${r['note']}');
    return b.toString().trim();
  }

  String _cities() {
    final rows = _maps(_d['reverse'])
      ..sort((a, b) => (_num(b['earth_percentile']) ?? 0)
          .compareTo(_num(a['earth_percentile']) ?? 0));
    if (rows.isEmpty) return 'No cities are stored.';
    final names = [for (final r in rows) '${r['label']}'];
    return 'Of the ${rows.length} cities stored, ${rows.first['label']} is the '
        'most like another world: closer to its best target than '
        '${_f(rows.first['earth_percentile'])}% of the Earth sites. '
        '${rows.last['label']} is the least, at ${_f(rows.last['earth_percentile'])}%. '
        'Ask about one by name: ${names.join(', ')}.';
  }
}