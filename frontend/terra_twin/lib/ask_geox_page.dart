// Ask GeoX screen: a chat-style page that answers questions about the
// stored results. The answers come from lib/ask_geox.dart, which reads only
// the bundled assets/geox_data.json, so this page works with the server off.
import 'dart:convert' show jsonDecode;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'ask_geox.dart';
import 'main.dart';

class AskGeoXPage extends StatefulWidget {
  /// Display name of the target to start with, for example 'Jezero Crater'.
  /// A custom point (or null) starts with no target chosen.
  final String? targetName;
  const AskGeoXPage({super.key, this.targetName});

  @override
  State<AskGeoXPage> createState() => _AskGeoXPageState();
}

class _Msg {
  final String text;
  final bool fromUser;
  const _Msg(this.text, this.fromUser);
}

class _AskGeoXPageState extends State<AskGeoXPage> {
  /// The data file is read once per app run and then reused.
  static AskGeoX? _engine;

  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _log = [];
  String? _targetId;
  bool _custom = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      var e = _engine;
      if (e == null) {
        final raw = jsonDecode(await rootBundle.loadString('assets/geox_data.json'));
        if (raw is! Map) throw const FormatException('not an object');
        e = _engine = AskGeoX(Map<String, dynamic>.from(raw));
      }
      final id = e.idForName(widget.targetName);
      if (!mounted) return;
      setState(() {
        _targetId = id;
        _custom = widget.targetName != null && id == null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'The data file bundled with the app could not be read.');
    }
  }

  void _ask(String text) {
    final e = _engine;
    final q = text.trim();
    if (e == null || q.isEmpty) return;
    setState(() {
      _log.add(_Msg(q, true));
      _log.add(_Msg(e.answer(_targetId, q), false));
      _ctrl.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  void _pickTarget(AskGeoX e, String? id) {
    if (id == null || id == _targetId) return;
    final name = e.targets.firstWhere((t) => t.id == id).name;
    setState(() {
      _targetId = id;
      _custom = false;
      if (_log.isNotEmpty) _log.add(_Msg('Now answering about $name.', false));
    });
  }

  @override
  Widget build(BuildContext c) {
    final e = _engine;
    final Widget body;
    if (_error != null) {
      body = Center(child: Text(_error!, style: const TextStyle(color: muted)));
    } else if (e == null) {
      body = const LoadingView();
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('ASK GEOX', style: mono(9)),
        const SizedBox(height: 6),
        Text('Ask about these results', style: head(24)),
        const SizedBox(height: 6),
        const Text(
            'Answers come only from the values stored in the app. If the data '
            'does not hold the answer, it says so instead of making one up.',
            style: TextStyle(color: muted, fontSize: 12, height: 1.4)),
        const SizedBox(height: 10),
        _picker(e),
        const SizedBox(height: 10),
        Expanded(child: _log.isEmpty ? _examples(e) : _chat()),
        const SizedBox(height: 8),
        _input(),
        const SizedBox(height: 10),
      ]);
    }
    return frame(c, 'ASK GEOX', body, back: true);
  }

  Widget _picker(AskGeoX e) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: line)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _targetId,
            isExpanded: true,
            dropdownColor: card,
            iconEnabledColor: muted,
            style: const TextStyle(color: fg, fontSize: 13),
            hint: Text(
                _custom
                    ? 'CUSTOM POINT · PICK A STORED TARGET'
                    : 'PICK A TARGET',
                style: mono(10)),
            items: [
              for (final t in e.targets)
                DropdownMenuItem<String>(
                    value: t.id,
                    child: Text('${t.name} · ${t.planet.toUpperCase()}',
                        overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => _pickTarget(e, v),
          ),
        ),
      );

  Widget _examples(AskGeoX e) => ListView(children: [
        Text('TRY ONE OF THESE', style: mono(9, accent)),
        const SizedBox(height: 8),
        for (final s in e.suggestions(_targetId))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GestureDetector(
              onTap: () => _ask(s),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: line)),
                child: Row(children: [
                  const Icon(Icons.help_outline, size: 15, color: teal),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(s,
                          style: const TextStyle(color: fg, fontSize: 12.5))),
                ]),
              ),
            ),
          ),
      ]);

  Widget _chat() => ListView.builder(
        controller: _scroll,
        itemCount: _log.length,
        itemBuilder: (_, i) {
          final m = _log[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Align(
              alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 460),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: m.fromUser ? accent.withAlpha(40) : card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: m.fromUser ? accent : line)),
                child: Text(m.text,
                    style: TextStyle(
                        color: m.fromUser ? fg : fg.withAlpha(225),
                        fontSize: 12.5,
                        height: 1.55)),
              ),
            ),
          );
        },
      );

  Widget _input() => Row(children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            onSubmitted: _ask,
            textInputAction: TextInputAction.send,
            style: const TextStyle(color: fg, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Ask about a site, a score, a city or the method',
              hintStyle: mono(10),
              isDense: true,
              filled: true,
              fillColor: card,
              contentPadding: const EdgeInsets.all(14),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: line)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: line)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: accent)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => _ask(_ctrl.text),
          child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                  color: accent, borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.send, size: 18, color: Colors.black)),
        ),
      ]);
}