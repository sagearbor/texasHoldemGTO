import 'package:flutter/material.dart';

import '../../learn/glossary.dart';
import '../theme.dart';

/// Searchable poker glossary. [initialQuery] pre-fills the search, e.g.
/// with the position chip that was tapped.
class GlossaryScreen extends StatefulWidget {
  final String initialQuery;
  const GlossaryScreen({super.key, this.initialQuery = ''});

  @override
  State<GlossaryScreen> createState() => _GlossaryScreenState();
}

class _GlossaryScreenState extends State<GlossaryScreen> {
  late final _query = TextEditingController(text: widget.initialQuery);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hits = searchGlossary(_query.text);
    final searching = _query.text.trim().isNotEmpty;
    final rows = <Widget>[];
    GlossaryCategory? last;
    for (final e in hits) {
      // Section headers only for the full list; search results are ranked.
      if (!searching && e.category != last) {
        last = e.category;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
          child: Text(glossaryCategoryLabels[e.category]!,
              style: t.labelLarge?.copyWith(color: Felt.accent(context))),
        ));
      }
      rows.add(_EntryCard(e));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Glossary')),
      body: Felt.narrow(Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: TextField(
            key: const Key('glossary-search'),
            controller: _query,
            autofocus: widget.initialQuery.isEmpty,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search ${glossary.length} terms (VPIP, squeeze…)',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: searching
                  ? IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(_query.clear),
                    )
                  : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: hits.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text('No term matches "${_query.text.trim()}".',
                        textAlign: TextAlign.center),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
                  children: rows,
                ),
        ),
      ])),
    );
  }
}

class _EntryCard extends StatelessWidget {
  final GlossaryEntry entry;
  const _EntryCard(this.entry);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.rich(TextSpan(children: [
            TextSpan(
                text: entry.term,
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (entry.long != null && entry.long != entry.term)
              TextSpan(text: '  ${entry.long}', style: t.bodySmall),
          ])),
          const SizedBox(height: 4),
          Text(entry.definition, style: t.bodyMedium),
        ]),
      ),
    );
  }
}

/// Opens the glossary, searching for [term] when given.
void openGlossary(BuildContext context, [String term = '']) {
  Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GlossaryScreen(initialQuery: term)));
}

/// App-bar button that opens the glossary.
class GlossaryButton extends StatelessWidget {
  const GlossaryButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Glossary',
        icon: const Icon(Icons.menu_book_outlined),
        onPressed: () => openGlossary(context),
      );
}

/// Makes an on-screen abbreviation (a seat chip, "VPIP") open its glossary
/// entry on tap or long press. Labels with no entry are left as they are.
class GlossaryLink extends StatelessWidget {
  final String term;
  final Widget child;

  /// Long press only, for widgets whose tap already does something.
  final bool longPressOnly;
  const GlossaryLink(
      {super.key,
      required this.term,
      required this.child,
      this.longPressOnly = false});

  @override
  Widget build(BuildContext context) {
    final e = lookupTerm(term);
    if (e == null) return child;
    void open() => openGlossary(context, e.term);
    return Semantics(
      onLongPressHint: 'what is $term?',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: longPressOnly ? null : open,
        onLongPress: open,
        child: child,
      ),
    );
  }
}
