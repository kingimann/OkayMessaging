import 'package:flutter/material.dart';

import '../state/account_verification.dart';
import '../state/community_note.dart';
import '../state/public_feed_store.dart';
import '../theme/app_theme.dart';
import 'verification_screen.dart';

/// Community notes on ONE public post: the reader fact-check surface. Shows the
/// note that has reached consensus (if any) at the top, every proposed note
/// with its rating below, and a composer to add your own. Rating a note is how
/// a note earns — or loses — its place on the post.
class CommunityNotesScreen extends StatefulWidget {
  final PublicPost post;
  const CommunityNotesScreen({super.key, required this.post});

  @override
  State<CommunityNotesScreen> createState() => _CommunityNotesScreenState();
}

class _CommunityNotesScreenState extends State<CommunityNotesScreen> {
  final _compose = TextEditingController();
  List<CommunityNote> _notes = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _compose.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final notes = await PublicFeedStore.instance.notesFor(widget.post.id);
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _loading = false;
    });
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  /// Adding OR rating a note asks for the full bar — phone, email and ID.
  /// A note is a claim about someone else's post; it should cost an account
  /// that has proven who it is. Returns true (and nudges) when blocked.
  bool _needsVerification(String action) {
    if (AccountVerification.fullyVerified) return false;
    final missing = AccountVerification.missingSentence;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$action needs full verification',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'Community notes fact-check other people\'s posts, so adding or '
                'rating one asks you to verify your phone, email and ID first.'
                '${missing.isEmpty ? '' : ' Still to verify: $missing.'}',
                style: TextStyle(color: AppColors.subtle(sheetContext)),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const VerificationScreen()));
                  },
                  child: const Text('Verify'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return true;
  }

  Future<void> _rate(CommunityNote note, bool helpful) async {
    if (_needsVerification('Rating a note')) return;
    try {
      await PublicFeedStore.instance.rateNote(note.id, helpful: helpful);
      await _load();
    } catch (e) {
      if (mounted) _snack('$e');
    }
  }

  Future<void> _add() async {
    final text = _compose.text.trim();
    if (text.isEmpty) return;
    if (_needsVerification('Adding a note')) return;
    setState(() => _busy = true);
    try {
      await PublicFeedStore.instance.proposeNote(widget.post.id, text);
      _compose.clear();
      if (mounted) FocusScope.of(context).unfocus();
      await _load();
      if (mounted) _snack('Note added — readers can rate it now.');
    } catch (e) {
      if (mounted) _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = CommunityNote.topShown(_notes);
    return Scaffold(
      appBar: AppBar(title: const Text('Community notes')),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    children: [
                      Text(
                        'Readers can add context to a post and rate each '
                        'other\'s notes. A note enough readers find helpful is '
                        'shown on the post. Notes are public.',
                        style: TextStyle(
                            fontSize: 13,
                            height: 1.35,
                            color: AppColors.subtle(context)),
                      ),
                      const SizedBox(height: 14),
                      if (shown != null) ...[
                        _NoteCard(
                            note: shown,
                            highlighted: true,
                            onRate: (h) => _rate(shown, h)),
                        const SizedBox(height: 16),
                        Text('ALL NOTES',
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                                color: AppColors.subtle(context))),
                        const SizedBox(height: 6),
                      ],
                      if (_notes.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text('No notes yet. Be the first to add context.',
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(color: AppColors.subtle(context))),
                        ),
                      for (final n in _notes)
                        if (n.id != shown?.id) ...[
                          _NoteCard(note: n, onRate: (h) => _rate(n, h)),
                          const SizedBox(height: 10),
                        ],
                    ],
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  12, 8, 12, 8 + MediaQuery.of(context).viewInsets.bottom),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _compose,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: PublicFeedStore.maxNoteLength,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Add context or a correction…',
                        border: OutlineInputBorder(),
                        counterText: '',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : _add,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Add'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One note with its rating controls.
class _NoteCard extends StatelessWidget {
  final CommunityNote note;
  final bool highlighted;
  final void Function(bool helpful) onRate;
  const _NoteCard(
      {required this.note, this.highlighted = false, required this.onRate});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtle = AppColors.subtle(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: highlighted
            ? scheme.primary.withValues(alpha: 0.06)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border.all(
          color: highlighted
              ? scheme.primary.withValues(alpha: 0.5)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                  note.isShown
                      ? Icons.fact_check
                      : Icons.hourglass_bottom_outlined,
                  size: 16,
                  color: note.isShown ? scheme.primary : subtle),
              const SizedBox(width: 6),
              Text(
                note.isShown ? 'Shown on this post' : 'Rating in progress',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: note.isShown ? scheme.primary : subtle),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(note.body, style: const TextStyle(fontSize: 14.5, height: 1.4)),
          const SizedBox(height: 8),
          Text(
            note.totalRatings == 0
                ? 'No ratings yet'
                : '${note.helpfulCount} of ${note.totalRatings} found this helpful',
            style: TextStyle(fontSize: 12, color: subtle),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _RateButton(
                icon: Icons.thumb_up_alt_outlined,
                label: 'Helpful',
                on: note.myRating == 1,
                onTap: () => onRate(true),
              ),
              const SizedBox(width: 8),
              _RateButton(
                icon: Icons.thumb_down_alt_outlined,
                label: 'Not helpful',
                on: note.myRating == -1,
                onTap: () => onRate(false),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RateButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _RateButton(
      {required this.icon,
      required this.label,
      required this.on,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        foregroundColor: on ? scheme.primary : null,
        side: BorderSide(
            color: on ? scheme.primary : scheme.outlineVariant),
      ),
    );
  }
}

/// The compact "Readers added context" card shown inline under a post when a
/// note has reached consensus. Fetches lazily (so it costs nothing until the
/// post is on screen focused) and taps through to the full notes screen.
class CommunityNoteInline extends StatefulWidget {
  final PublicPost post;
  const CommunityNoteInline({super.key, required this.post});

  @override
  State<CommunityNoteInline> createState() => _CommunityNoteInlineState();
}

class _CommunityNoteInlineState extends State<CommunityNoteInline> {
  CommunityNote? _shown;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final notes = await PublicFeedStore.instance.notesFor(widget.post.id);
    if (!mounted) return;
    setState(() => _shown = CommunityNote.topShown(notes));
  }

  @override
  Widget build(BuildContext context) {
    final note = _shown;
    if (note == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => CommunityNotesScreen(post: widget.post),
        )),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
            border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.fact_check_outlined,
                      size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text('Readers added context',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 6),
              Text(note.body,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, height: 1.4)),
            ],
          ),
        ),
      ),
    );
  }
}
