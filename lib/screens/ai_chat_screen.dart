import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/ai_assistant.dart';
import '../state/ai_attachment.dart';
import '../state/ai_consent.dart';
import '../state/ai_memory.dart';
import '../state/ai_persona.dart';
import '../state/ai_pass_store.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../util/file_moderation.dart';
import '../util/mini_markdown.dart';
import '../util/photo_prep.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/phone_gate.dart';

/// The built-in AI assistant chat — "Okay AI", a general-purpose helper in the
/// shape of Grok or Claude. A dedicated surface, deliberately separate from the
/// human chat list: what you type here goes to a hosted model, and the label
/// says so, because talking to a machine is a different thing from talking to a
/// person the app is keeping private.
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  /// Test seam for picking a file without the platform picker. Given whether
  /// the image-only path was chosen, returns (bytes, name) or null to cancel.
  @visibleForTesting
  static Future<(Uint8List, String)?> Function(bool imageOnly)? debugPick;

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Images/files staged for the next send, shown above the composer.
  final List<AiAttachment> _pending = [];

  static const _starters = [
    'Explain a hard idea simply',
    'Draft a message for me',
    'Give me ideas for…',
    'Summarize this text',
  ];

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty && _pending.isEmpty) return;
    if (AiAssistant.instance.needsUpgrade) {
      _showUpgrade();
      return;
    }
    final attachments = List<AiAttachment>.from(_pending);
    _input.clear();
    setState(_pending.clear);
    await AiAssistant.instance.send(text, attachments: attachments);
    _toBottom();
  }

  /// Offers the two things a hosted assistant can actually read: a photo (seen
  /// by a vision model) or a text file (its content folded in). Anything else
  /// is refused when picked, with a plain reason.
  Future<void> _attach() async {
    final choice = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Photo'),
              subtitle: const Text('Okay AI can look at it'),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('File'),
              subtitle: const Text('A text file it can read'),
              onTap: () => Navigator.of(sheetContext).pop(false),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _pick(imageOnly: choice);
  }

  Future<void> _pick({required bool imageOnly}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      Uint8List? bytes;
      String name = '';
      final override = AiChatScreen.debugPick;
      if (override != null) {
        final picked = await override(imageOnly);
        if (picked == null) return;
        bytes = picked.$1;
        name = picked.$2;
      } else {
        final result = await FilePicker.pickFiles(
          type: imageOnly ? FileType.image : FileType.any,
          withData: true,
        );
        final file = result?.files.firstOrNull;
        bytes = file?.bytes;
        name = file?.name ?? '';
      }
      if (bytes == null || bytes.isEmpty) return;
      final attachment = AiAttachment.prepare(bytes, name);
      if (!mounted) return;
      setState(() => _pending.add(attachment));
    } on FileRejected catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.reason)));
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Couldn\'t add that file.')));
    }
  }

  /// The pay gate: the free daily allowance is spent, so offer the pass. Test
  /// mode simulates the purchase; the real price is the owner's to set later.
  Future<void> _showUpgrade() async {
    final messenger = ScaffoldMessenger.of(context);
    final go = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.auto_awesome,
                  size: 36, color: Theme.of(sheetContext).colorScheme.primary),
              const SizedBox(height: 8),
              const Text('You\'ve used today\'s free messages',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'Free includes ${AiAssistant.freePerDay} messages a day. '
                'Subscribe for unlimited Okay AI.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(true),
                child: const Text('Subscribe to Okay AI'),
              ),
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(false),
                child: const Text('Maybe later'),
              ),
            ],
          ),
        ),
      ),
    );
    if (go != true || !mounted) return;
    final result = await AiPassStore.instance.subscribe();
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
        content: Text(result.ok
            ? 'You\'re subscribed — enjoy unlimited Okay AI.'
            : 'That didn\'t go through — nothing was charged.')));
  }

  /// Records a 👍/👎 on an assistant reply. If the user hasn't opted in to
  /// helping improve Okay AI, offer that first — the rating only becomes
  /// training data with consent.
  Future<void> _rate(int index, int rating) async {
    await AiAssistant.instance.rate(index, rating);
    if (rating != 0 && !AiConsent.instance.on && mounted) {
      final on = await showModalBottomSheet<bool>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.volunteer_activism_outlined, size: 32),
                const SizedBox(height: 8),
                const Text('Help improve Okay AI?',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  'Turn this on and your rated chats WITH OKAY AI help train it '
                  '— never your private messages, which stay encrypted on your '
                  'device. You can turn it off anytime.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Theme.of(sheetContext)
                          .colorScheme
                          .onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                  child: const Text('Turn on'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                  child: const Text('Not now'),
                ),
              ],
            ),
          ),
        ),
      );
      if (on == true) {
        await AiConsent.instance.set(true);
        // Now that consent is on, submit the rating that prompted this.
        await AiAssistant.instance.rate(index, 0); // clear then re-apply
        await AiAssistant.instance.rate(index, rating);
      }
    }
  }

  /// What Okay AI remembers about you — viewable and deletable, on this device
  /// only.
  void _showMemory() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: AiMemory.instance,
        builder: (context, _) {
          final items = AiMemory.instance.items;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('What Okay AI remembers',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                      if (items.isNotEmpty)
                        TextButton(
                          onPressed: () => AiMemory.instance.clear(),
                          child: const Text('Forget all'),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'Kept on this device to make answers more personal. Only '
                    'from what you tell Okay AI — never your private chats.',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(sheetContext)
                            .colorScheme
                            .onSurfaceVariant),
                  ),
                ),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, 24),
                    child: Text('Nothing yet — the more you chat, the more '
                        'it learns about you.'),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final item in items)
                          ListTile(
                            leading: const Icon(Icons.circle, size: 8),
                            title: Text(item),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: 'Forget this',
                              onPressed: () => AiMemory.instance.remove(item),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Pick Okay AI's personality — a tone it follows while keeping its limits.
  /// The Custom option takes the user's own words.
  void _showPersona() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: AiPersona.instance,
        builder: (context, _) {
          final selectedId = AiPersona.instance.id;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Personality',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'How Okay AI talks to you. It still keeps its limits — a '
                    'personality changes the tone, not the rules.',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(sheetContext)
                            .colorScheme
                            .onSurfaceVariant),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final p in AiPersona.presets)
                        ListTile(
                          leading: Icon(
                            p.id == selectedId
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: p.id == selectedId
                                ? Theme.of(sheetContext).colorScheme.primary
                                : null,
                          ),
                          title: Text(p.label),
                          subtitle: Text(p.id == 'custom' &&
                                  AiPersona.instance.custom.isNotEmpty
                              ? AiPersona.instance.custom
                              : p.blurb),
                          onTap: () async {
                            if (p.id == 'custom') {
                              Navigator.of(sheetContext).pop();
                              await _editCustomPersona();
                            } else {
                              await AiPersona.instance.select(p.id);
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Free-text personality — the user describes the voice they want.
  Future<void> _editCustomPersona() async {
    final controller =
        TextEditingController(text: AiPersona.instance.custom);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Custom personality'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          maxLength: 300,
          decoration: const InputDecoration(
            hintText: 'e.g. A patient tutor who explains with examples',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Use'),
          ),
        ],
      ),
    );
    if (result != null) {
      await AiPersona.instance.select('custom', customText: result);
    }
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // A name-only (numberless) account can't use Okay AI: it has no server
    // session, so nothing holds it to the usage limits, and the assistant is a
    // paid, abuse-prone surface. Add a number to unlock it.
    if (Session.instance.isNumberless) {
      return const PhoneGate(
        title: 'Okay AI',
        reason: 'The assistant runs on a server, and an account with no phone '
            'number can\'t be held to its usage limits. Add a number to chat '
            'with Okay AI.',
        child: SizedBox.shrink(),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: ListenableBuilder(
          listenable: AiAssistant.instance,
          builder: (context, _) {
            final incognito = AiAssistant.instance.incognito;
            return Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor:
                      incognito ? Colors.grey.shade800 : scheme.primary,
                  child: Icon(
                      incognito
                          ? Icons.visibility_off_outlined
                          : Icons.auto_awesome,
                      size: 17,
                      color: incognito ? Colors.white : scheme.onPrimary),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Okay AI',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    Text(
                        incognito
                            ? 'Incognito · not saved'
                            : 'AI assistant · can make mistakes',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: incognito
                                ? scheme.primary
                                : Colors.grey)),
                  ],
                ),
              ],
            );
          },
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'memory') {
                _showMemory();
              } else if (v == 'persona') {
                _showPersona();
              } else if (v == 'incognito') {
                final on = !AiAssistant.instance.incognito;
                final messenger = ScaffoldMessenger.of(context);
                await AiAssistant.instance.setIncognito(on);
                messenger.showSnackBar(SnackBar(
                    content: Text(on
                        ? 'Incognito on — this chat isn\'t saved and won\'t '
                            'be remembered.'
                        : 'Incognito off — your saved chat is back.')));
              } else if (v == 'improve') {
                final messenger = ScaffoldMessenger.of(context);
                await AiConsent.instance.set(!AiConsent.instance.on);
                messenger.showSnackBar(SnackBar(
                    content: Text(AiConsent.instance.on
                        ? 'Thanks — your rated Okay AI chats help train it.'
                        : 'Turned off. New chats won\'t be collected.')));
              } else if (v == 'clear') {
                final ok = await showAppConfirmDialog(
                  context,
                  icon: Icons.delete_outline,
                  title: 'Clear this conversation?',
                  message: 'The whole chat with Okay AI is removed from this '
                      'device. This can\'t be undone.',
                  confirmLabel: 'Clear',
                  destructive: true,
                );
                if (ok) await AiAssistant.instance.clear();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'incognito',
                  child: Text(AiAssistant.instance.incognito
                      ? 'Turn off incognito'
                      : 'Incognito chat')),
              const PopupMenuItem(
                  value: 'persona', child: Text('Personality')),
              const PopupMenuItem(
                  value: 'memory', child: Text('What Okay AI remembers')),
              PopupMenuItem(
                  value: 'improve',
                  child: Text(AiConsent.instance.on
                      ? 'Stop helping improve Okay AI'
                      : 'Help improve Okay AI')),
              const PopupMenuItem(
                  value: 'clear', child: Text('Clear conversation')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            // Tapping anywhere in the conversation dismisses the keyboard —
            // there is no Done key on the message field, so this is the way
            // out. Dragging the list does it too (below).
            child: GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              behavior: HitTestBehavior.opaque,
              child: ListenableBuilder(
              listenable: AiAssistant.instance,
              builder: (context, _) {
                final turns = AiAssistant.instance.turns;
                if (turns.isEmpty) return _empty(context);
                final sending = AiAssistant.instance.sending;
                return ListView.builder(
                  controller: _scroll,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  itemCount: turns.length + (sending ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == turns.length) return const _Typing();
                    return _Bubble(
                      turn: turns[i],
                      onRate:
                          turns[i].fromUser ? null : (r) => _rate(i, r),
                    );
                  },
                );
              },
            ),
            ),
          ),
          _composer(context, scheme),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: scheme.primary,
              child: Icon(Icons.auto_awesome,
                  size: 30, color: scheme.onPrimary),
            ),
            const SizedBox(height: 16),
            const Text('Ask Okay AI anything',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              'A helpful assistant, built in. It only sees what you type here — '
              'never your private chats.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subtle(context), fontSize: 14),
            ),
            const SizedBox(height: 22),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final s in _starters)
                  ActionChip(label: Text(s), onPressed: () => _send(s)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer(BuildContext context, ColorScheme scheme) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pending.isNotEmpty) _pendingStrip(scheme),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ListenableBuilder(
                  listenable: AiAssistant.instance,
                  builder: (context, _) => IconButton(
                    onPressed:
                        AiAssistant.instance.sending ? null : _attach,
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: 'Attach a photo or file',
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Message Okay AI',
                      filled: true,
                      fillColor: scheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 6),
                ListenableBuilder(
                  listenable: AiAssistant.instance,
                  builder: (context, _) => IconButton.filled(
                    onPressed:
                        AiAssistant.instance.sending ? null : () => _send(),
                    icon: const Icon(Icons.arrow_upward),
                    tooltip: 'Send',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _pendingStrip(ColorScheme scheme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, bottom: 6),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _pending.length; i++)
              _PendingChip(
                attachment: _pending[i],
                onRemove: () => setState(() => _pending.removeAt(i)),
              ),
          ],
        ),
      ),
    );
  }
}

/// A staged attachment above the composer, with a remove button.
class _PendingChip extends StatelessWidget {
  final AiAttachment attachment;
  final VoidCallback onRemove;
  const _PendingChip({required this.attachment, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumb = attachment.isImage
        ? PhotoPrep.bytesFromDataUri(attachment.thumbDataUri)
        : null;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (thumb != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(thumb,
                width: 54, height: 54, fit: BoxFit.cover),
          )
        else
          Container(
            constraints: const BoxConstraints(maxWidth: 180),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.description_outlined, size: 16),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ),
        Positioned(
          top: -8,
          right: -8,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surface,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.outlineVariant),
              ),
              padding: const EdgeInsets.all(1),
              child: Icon(Icons.close, size: 15, color: scheme.onSurface),
            ),
          ),
        ),
      ],
    );
  }
}

/// Renders an assistant reply as light Markdown: paragraphs with inline **bold**
/// and `code`, and fenced code blocks as monospaced, copyable panels.
class _RichReply extends StatelessWidget {
  final String text;
  const _RichReply({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocks = MiniMarkdown.blocks(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          if (blocks[i].isCode)
            _CodeBlock(code: blocks[i].text, language: blocks[i].language)
          else
            SelectableText.rich(
              TextSpan(
                children: [
                  for (final s in MiniMarkdown.inline(blocks[i].text))
                    TextSpan(
                      text: s.text,
                      style: TextStyle(
                        fontWeight: s.bold ? FontWeight.w700 : null,
                        fontFamily: s.code ? 'monospace' : null,
                        backgroundColor:
                            s.code ? scheme.surface : null,
                      ),
                    ),
                ],
              ),
              style: TextStyle(
                  fontSize: 15, height: 1.35, color: scheme.onSurface),
            ),
        ],
      ],
    );
  }
}

/// A fenced code block: monospaced, horizontally scrollable, with a copy button
/// — the thing that makes coding answers actually usable.
class _CodeBlock extends StatelessWidget {
  final String code;
  final String language;
  const _CodeBlock({required this.code, required this.language});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  language.isEmpty ? 'code' : language,
                  style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600),
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copied')));
                },
                icon: const Icon(Icons.copy, size: 15),
                label: const Text('Copy'),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
              ),
            ],
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: SelectableText(
              code,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// An attachment as it appears inside a sent bubble: a thumbnail for an image,
/// a small file chip for a text file.
class _AttachmentTile extends StatelessWidget {
  final AiAttachmentRef ref;
  const _AttachmentTile({required this.ref});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumb =
        ref.isImage ? PhotoPrep.bytesFromDataUri(ref.thumb) : null;
    if (thumb != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(thumb, width: 150, height: 150, fit: BoxFit.cover),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ref.isImage ? Icons.image_outlined : Icons.description_outlined,
              size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(ref.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final AiTurn turn;
  final ValueChanged<int>? onRate;
  const _Bubble({required this.turn, this.onRate});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = turn.fromUser;
    return Column(
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (turn.attachments.isNotEmpty)
          Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: mine ? WrapAlignment.end : WrapAlignment.start,
                children: [
                  for (final a in turn.attachments) _AttachmentTile(ref: a),
                ],
              ),
            ),
          ),
        if (turn.text.isNotEmpty)
          Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.82),
              decoration: BoxDecoration(
                color: mine ? scheme.primary : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              // The user's own words are plain; an assistant reply is rendered
              // as light Markdown so code and emphasis read the way it meant.
              child: mine
                  ? SelectableText(
                      turn.text,
                      // onPrimary, not a hardcoded white: the Ink theme's
                      // primary is LIGHT, so white text on it is invisible.
                      style: TextStyle(
                          fontSize: 15,
                          height: 1.35,
                          color: scheme.onPrimary),
                    )
                  : _RichReply(text: turn.text),
            ),
          ),
        // 👍/👎 on an assistant reply — the curation signal for training.
        if (!mine && onRate != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RateButton(
                  icon: Icons.thumb_up_outlined,
                  filled: Icons.thumb_up,
                  active: turn.rating == 1,
                  onTap: () => onRate!(1),
                ),
                _RateButton(
                  icon: Icons.thumb_down_outlined,
                  filled: Icons.thumb_down,
                  active: turn.rating == -1,
                  onTap: () => onRate!(-1),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _RateButton extends StatelessWidget {
  final IconData icon;
  final IconData filled;
  final bool active;
  final VoidCallback onTap;
  const _RateButton(
      {required this.icon,
      required this.filled,
      required this.active,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 16,
      color: active ? scheme.primary : scheme.onSurfaceVariant,
      icon: Icon(active ? filled : icon),
      onPressed: onTap,
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SizedBox(
          width: 34,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < 3; i++)
                _Dot(delay: Duration(milliseconds: i * 150)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  final Duration delay;
  const _Dot({required this.delay});
  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 700))
    ..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1).animate(_c),
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            shape: BoxShape.circle),
      ),
    );
  }
}
