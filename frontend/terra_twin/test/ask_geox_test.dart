// Tests for Ask GeoX (lib/ask_geox.dart).
//
// Run from the project folder:  flutter test test/ask_geox_test.dart
//
// The 'exact answers' group checks full answer text against the current
// assets/geox_data.json. If that file is replaced by a new pipeline run, those
// expected strings must be updated. The other groups do not depend on the
// exact numbers.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terra_twin/ask_geox.dart';

void main() {
  final data = jsonDecode(File('assets/geox_data.json').readAsStringSync())
      as Map<String, dynamic>;
  final ask = AskGeoX(data);

  test('reads the 20 stored targets', () {
    expect(ask.targets.length, 20);
    expect(ask.idForName('Jezero Crater'), 'mars_jezero');
    expect(ask.idForName('Custom point'), isNull);
  });

  group('questions go to the right topic', () {
    const cases = <(String?, String, String)>[
      ('mars_jezero', 'Why does China, grid site rank first?', 'site'),
      ('mars_jezero', 'How accurate is this?', 'accuracy'),
      ('mars_jezero', 'Does it work?', 'accuracy'),
      ('mars_jezero', 'How does it work?', 'method'),
      ('mars_jezero', 'How was the score calculated?', 'method'),
      ('mars_jezero', 'How does the trend work?', 'trend'),
      ('mars_jezero', 'Is Jezero becoming more Mars-like?', 'trend'),
      ('mars_jezero', 'Has anything changed over the years?', 'trend'),
      ('mars_jezero', 'What can\'t Earth reproduce?', 'limits'),
      ('mars_jezero', 'Is the gravity the same?', 'limits'),
      ('mars_jezero', 'Where does the data come from?', 'sources'),
      ('mars_jezero', 'Which datasets do you use?', 'sources'),
      ('mars_jezero', 'Why is there no picture for Shackleton?', 'visualoff'),
      ('mars_jezero', 'Why is Cabeus dark?', 'visualoff'),
      ('mars_jezero', 'How important is the visual score?', 'fusion'),
      ('mars_jezero', 'What does DINOv2 do?', 'fusion'),
      ('mars_jezero', 'How Mars-like is Chattogram?', 'city'),
      ('mars_jezero', 'Tell me about Cox\'s Bazar', 'city'),
      ('mars_jezero', 'Which city is most like Mars?', 'city'),
      ('mars_jezero', 'Which site is best for a rover?', 'mission'),
      ('mars_jezero', 'Where should we search for life?', 'mission'),
      ('mars_jezero', 'Best site for ISRU?', 'mission'),
      ('mars_jezero', 'Which sites are in Chile?', 'region'),
      ('mars_jezero', 'Any sites in the USA?', 'region'),
      ('mars_jezero', 'Top 10 sites', 'top'),
      ('mars_jezero', 'Which site ranks first?', 'top'),
      ('mars_jezero', 'Which known analogues appear?', 'known'),
      ('mars_jezero', 'Tell me about Gale Crater', 'targetinfo'),
      ('mars_jezero', 'How cold is Jezero?', 'targetinfo'),
      ('mars_jezero', 'Hello', 'help'),
      ('mars_jezero', 'Thanks!', 'help'),
      ('mars_jezero', 'asdf qwerty', ''),
      ('mars_jezero', '   ', 'empty'),
      ('mars_jezero', 'Is Atacama a good analogue?', 'site'),
      ('mars_jezero', 'Is MDRS any good?', 'site'),
      ('mars_jezero', 'Compare Atacama and Death Valley', 'compare'),
      ('mars_jezero', 'How is Death Valley different?', 'site'),
      ('moon_taurus_littrow', 'Compare Saudi Arabia, grid site and Algeria, grid site', 'compare'),
      (null, 'How accurate is this?', 'accuracy'),
      (null, 'Which site is best for a rover?', 'mission'),
      (null, 'How Mars-like is Dhaka?', 'city'),
      (null, 'What are the best sites for Gale Crater?', 'top'),
    ];
    for (final c in cases) {
      test('${c.$2} (${c.$1})', () => expect(ask.topic(c.$1, c.$2), c.$3));
    }
  });

  group('every example question is understood', () {
    for (final id in <String?>[...ask.targets.map((t) => t.id), null]) {
      test('examples for ${id ?? 'a custom point'}', () {
        for (final s in ask.suggestions(id)) {
          final topic = ask.topic(id, s);
          expect(topic, isNot(''), reason: s);
          expect(topic, isNot('help'), reason: s);
          expect(ask.answer(id, s).startsWith('I can only answer'), isFalse, reason: s);
        }
      });
    }
  });

  group('exact answers from the current data file', () {
    const cases = <(String?, String, String)>[
      ('mars_jezero', 'Why does China, grid site rank first?',
          'China, grid site is ranked 1 of the 25 stored results for Jezero Crater, with an overall score of 95.7. That comes from 100.0 on measured environment and 83.0 on how the landscape looks. Close matches: slope, surface roughness, lack of vegetation, exposed bare ground. Poor matches: surface temperature, day to night swing. Its strongest mission use is rover mobility (96.5). It is a candidate, not yet a documented analogue, in China (35.00, 87.50).'),
      ('mars_jezero', 'Compare Atacama and Mars Desert Research Station',
          'For Jezero Crater: Atacama Desert (Yungay) is rank 3 with 90.7, and Mars Desert Research Station is rank 5 with 88.1. Atacama Desert (Yungay) is ahead by 2.6 points. The biggest difference is bare ground: 100.0 against 72.3.'),
      ('mars_jezero', 'Compare Atacama and Death Valley',
          'Atacama Desert (Yungay) is ranked 3 of the 25 stored results for Jezero Crater, with an overall score of 90.7. That comes from 94.9 on measured environment and 78.2 on how the landscape looks. Close matches: slope, lack of vegetation, exposed bare ground. Poor matches: surface temperature, day to night swing. Its strongest mission use is geology (83.0). It is already a documented analogue site, in Chile (-24.08, -69.92). Death Valley is not among the 25 stored results for Jezero Crater. It does appear for Shackleton Crater (rank 2), Malapert Massif (rank 9), Haworth (rank 1), de Gerlache Rim (rank 4), Cabeus Crater (rank 1).'),
      ('mars_jezero', 'Which site is best for a rover?',
          'For rover mobility at Jezero Crater, the best stored site is China, grid site (96.5), then Oman, grid site (94.4), then Niger, grid site (89.9). This mission score is the average similarity of slope and surface roughness, so it can differ from the overall rank.'),
      ('mars_jezero', 'Any sites in the USA?',
          '2 stored results for Jezero Crater are in United States and United States (Hawaii):\nMars Desert Research Station, rank 5, score 88.1\nMauna Kea, Hawaii, rank 20, score 79.6'),
      ('mars_utopia', 'Is the best site becoming more like Utopia Planitia?',
          'GeoX tracks the best-matching site, Mongolia, grid site, for Utopia Planitia from 2001 to 2024. It measures the change with Sen\'s slope and checks whether it is real with the Mann-Kendall test. The slope is -0.0204 points a year and the p value is 0.005. From the first year to the last, the similarity moved by -0.16 points. This trend is statistically significant: the site is slowly becoming less like Utopia Planitia. Across all targets, 3 of 20 show a significant trend.'),
      ('mars_jezero', 'How does the trend work?',
          'GeoX tracks the best-matching site, China, grid site, for Jezero Crater from 2001 to 2024. It measures the change with Sen\'s slope and checks whether it is real with the Mann-Kendall test. The slope is -0.0045 points a year and the p value is 0.264. From the first year to the last, the similarity moved by -0.18 points. This is not statistically significant, so GeoX does not claim a trend. Across all targets, 3 of 20 show a significant trend.'),
      ('moon_cabeus', 'Why is there no picture for Cabeus Crater?',
          'Cabeus Crater has no usable picture score: target tile is flat, no texture to compare. Instead of pretending to see, GeoX scores it on the measured environment alone. 3 of 20 targets are in this situation: Shackleton Crater, Haworth, Cabeus Crater.'),
      ('mars_jezero', 'How accurate is this?',
          'For Jezero Crater, the documented analogue sites average 54.6 against 14.7 for the control sites (higher is better). Their average rank among the 600 Earth sites is 83 against 419, and the p value is below 0.001. Across the run, 19 of 19 targets in scope separate the 11 known analogues from the 10 controls. Out of scope: Planum Boreum. On this benchmark the environmental channel alone separates known from control more cleanly than the fusion does. The weight was fixed in advance and was not moved to flatter the result.'),
      ('mars_planum_boreum', 'How accurate is this?',
          'The check does not apply to Planum Boreum: the known-analogue list is curated for dry rocky sites, so it cannot judge an ice target; this row is reported but not counted. Across the run, 19 of 19 targets in scope separate the 11 known analogues from the 10 controls. Out of scope: Planum Boreum. On this benchmark the environmental channel alone separates known from control more cleanly than the fusion does. The weight was fixed in advance and was not moved to flatter the result.'),
      ('mars_jezero', 'How much does the satellite picture count?',
          'The overall score blends 75% measured environment with 25% picture similarity from dinov2_vits14. For Jezero Crater, known analogues beat the controls by 47.6 points with environment only, 16.7 with pictures only, and 39.8 with the blend. On this benchmark the environmental channel alone separates known from control more cleanly than the fusion does. The weight was fixed in advance and was not moved to flatter the result.'),
      ('mars_jezero', 'How does it work?',
          'GeoX searched 600 Earth sites against 20 targets. For Jezero Crater it compares 6 measured features: slope, surface roughness, surface temperature, day to night swing, vegetation (NDVI), bare ground. Each feature is put on a shared scale (robust scaler), and every Earth site gets an environment score for how close its values are to the target. Where the target has a usable picture, a picture score from dinov2_vits14 is added, 75% environment and 25% picture. Environmental and visual similarity are rescaled across the candidate set before fusing, so the weight controls influence. Scores therefore rank within one target and are not an absolute physical measurement. Elevation and aridity are dropped for every target: heights use a different reference surface on each world, and aridity is defined from rainfall.'),
      ('mars_jezero', 'What can Earth not reproduce?',
          'No place on Earth reproduces another world. Gravity, air pressure, radiation, vacuum and the make-up of the air are all different, and GeoX does not claim otherwise. It compares terrain, temperature, vegetation and bare ground, which is what a field test on Earth can stand in for. Similarity in selected measured features, not physical equivalence.'),
      ('mars_jezero', 'Where does the data come from?',
          'The data comes from MODIS, Copernicus DEM, ESA WorldCover, Global Aridity Index, Sentinel-2, NASA Solar System Treks. Pictures are compared with dinov2_vits14. The Jezero Crater picture is NES_JEZ_MID_Visible_Mosaic_HiRISE_CTX_HRSC_GCS_MARS_07-10-2018 from NASA Trek, at 41 m per pixel.'),
      ('mars_elysium', 'Which known analogues appear?',
          'Documented analogue sites in the stored results for Elysium Planitia: Mars Desert Research Station (rank 22). The accuracy check uses 11 documented analogues and 10 control sites.'),
      ('mars_gale', 'Top 5 sites',
          'Top 5 for Gale Crater:\n1. Argentina, grid site, score 91.3\n2. China, grid site, score 89.3\n3. Atacama Desert (Yungay), score 84.2 (documented analogue)\n4. Algeria, grid site, score 83.8\n5. Mars Desert Research Station, score 83.8 (documented analogue)'),
      ('moon_south_pole', 'Tell me about the south pole',
          'Lunar South Pole is on the Moon: sunlit high ground right beside permanent ice traps. Stored values: surface temperature -50.0 °C, measured; day to night swing 90.0 °C, estimated; slope 8.0°, estimated; roughness 150.0 m, estimated; vegetation (NDVI) 0.00, measured; bare ground 1.00, measured. Elevation and dryness are not compared for other worlds.'),
      ('mars_jezero', 'How Mars-like is Chattogram?',
          'Chattogram is about average among Earth locations. Its environment is closer to its best-matching target than 56.8% of the 600 Earth sites searched. Closest Mars target: Planum Boreum (environment score 41.6). Closest Moon target: Connecting Ridge (environment score 8.8). For Jezero Crater its environment score is 9.7, higher than 40.8% of the Earth sites. No inhabited place resembles a Mars or Moon base site. The percentile says how this city compares with the 600 Earth sites that were searched, which is the honest version of the question.'),
      ('mars_jezero', 'Which city is most like Mars?',
          'Of the 14 cities stored, Riyadh is the most like another world: closer to its best target than 80.2% of the Earth sites. Cox\'s Bazar is the least, at 45.8%. Ask about one by name: Riyadh, Reykjavik, Dubai, Las Vegas, Washington DC, Cairo, Lima, Sydney, Mumbai, Chattogram, Sylhet, Rajshahi, Dhaka, Cox\'s Bazar.'),
      (null, 'Which site is best for a rover?',
          'This page is answering for a custom point. Stored answers exist only for the 20 standard targets, because a custom point is scored live and nothing about it is saved. Pick a target from the list at the top to ask about it.'),
      ('mars_jezero', 'asdf qwerty',
          'I can only answer from the values stored in the app, and I could not match that question to them. You can ask about a site by name, the top sites, a mission (rover, geology, astrobiology, EVA, ISRU), trends, accuracy, the satellite pictures, the data sources, or a city. For example: "Why does China, grid site rank first?", "How accurate is this?", "Is the best site becoming more like Jezero Crater?".'),
    ];
    for (final c in cases) {
      test('${c.$2} (${c.$1})', () => expect(ask.answer(c.$1, c.$2), c.$3));
    }
  });

  test('never crashes and never prints a missing value', () {
    const questions = <String>[
      '   ',
      'Any sites in the USA?',
      'Best site for ISRU?',
      'Compare Atacama and Death Valley',
      'Compare Atacama and Mars Desert Research Station',
      'Compare Saudi Arabia, grid site and Algeria, grid site',
      'Does it work?',
      'Has anything changed over the years?',
      'Hello',
      'How Mars-like is Chattogram?',
      'How Mars-like is Dhaka?',
      'How accurate is this?',
      'How cold is Jezero?',
      'How does it work?',
      'How does the trend work?',
      'How important is the visual score?',
      'How is Death Valley different?',
      'How much does the satellite picture count?',
      'How was the score calculated?',
      'Is Atacama a good analogue?',
      'Is Jezero becoming more Mars-like?',
      'Is MDRS any good?',
      'Is the best site becoming more like Utopia Planitia?',
      'Is the gravity the same?',
      'Tell me about Cox\'s Bazar',
      'Tell me about Gale Crater',
      'Tell me about the south pole',
      'Thanks!',
      'Top 10 sites',
      'Top 5 sites',
      'What are the best sites for Gale Crater?',
      'What can Earth not reproduce?',
      'What can\'t Earth reproduce?',
      'What does DINOv2 do?',
      'Where does the data come from?',
      'Where should we search for life?',
      'Which city is most like Mars?',
      'Which datasets do you use?',
      'Which known analogues appear?',
      'Which site is best for a rover?',
      'Which site ranks first?',
      'Which sites are in Chile?',
      'Why does China, grid site rank first?',
      'Why is Cabeus dark?',
      'Why is there no picture for Cabeus Crater?',
      'Why is there no picture for Shackleton?',
      'asdf qwerty',
    ];
    for (final id in <String?>[...ask.targets.map((t) => t.id), null]) {
      for (final q in [...questions, ...ask.suggestions(id)]) {
        final a = ask.answer(id, q);
        expect(a, isNotEmpty, reason: '$id / $q');
        expect(a.contains('null'), isFalse, reason: '$id / $q: $a');
        expect(a.contains('not recorded'), isFalse, reason: '$id / $q: $a');
      }
    }
  });
}