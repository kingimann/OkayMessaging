import 'package:flutter/material.dart';

import '../state/ai_assistant.dart';
import '../state/ai_memory.dart';
import '../state/ai_pass_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';

/// The built-in AI assistant chat — "Okay AI", a general-purpose helper in the
/// shape of Grok or Claude. A dedicated surface, deliberately separate from the
/// human chat list: what you type here goes to a hosted model, and the label
/// says so, because talking to a machine is a different thing from talking to a
/// person the app is keeping private.
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

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
    if (text.isEmpty) return;
    if (AiAssistant.instance.needsUpgrade) {
      _showUpgrade();
      return;
    }
    _input.clear();
    await AiAssistant.instance.send(text);
    _toBottom();
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: scheme.primary,
              child: const Icon(Icons.auto_awesome,
                  size: 17, color: Colors.white),
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Okay AI',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                Text('AI assistant · can make mistakes',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey)),
              ],
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'memory') {
                _showMemory();
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
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'memory', child: Text('What Okay AI remembers')),
              PopupMenuItem(
                  value: 'clear', child: Text('Clear conversation')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: AiAssistant.instance,
              builder: (context, _) {
                final turns = AiAssistant.instance.turns;
                if (turns.isEmpty) return _empty(context);
                final sending = AiAssistant.instance.sending;
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  itemCount: turns.length + (sending ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == turns.length) return const _Typing();
                    return _Bubble(turn: turns[i]);
                  },
                );
              },
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
              child: const Icon(Icons.auto_awesome,
                  size: 30, color: Colors.white),
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
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
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
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                onPressed: AiAssistant.instance.sending ? null : () => _send(),
                icon: const Icon(Icons.arrow_upward),
                tooltip: 'Send',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final AiTurn turn;
  const _Bubble({required this.turn});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = turn.fromUser;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: mine ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(
          turn.text,
          style: TextStyle(
              fontSize: 15,
              height: 1.35,
              color: mine ? Colors.white : scheme.onSurface),
        ),
      ),
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
