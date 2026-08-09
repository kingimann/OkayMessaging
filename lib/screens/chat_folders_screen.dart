import 'package:flutter/material.dart';

import '../state/chat_folders.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';

/// Manage the Telegram-style folder tabs: create, rename, reorder, delete,
/// and choose which conversations sit in each one.
class ChatFoldersScreen extends StatelessWidget {
  const ChatFoldersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final folders = ChatFolders.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Chat folders')),
      body: ListenableBuilder(
        listenable: folders,
        builder: (context, _) {
          final names = folders.folders;
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Text(
                  'Folders become tabs above your chat list. A chat is in a '
                  'folder because you put it there, and stays in the main '
                  'list either way.',
                  style: TextStyle(
                      fontSize: 13.5,
                      height: 1.4,
                      color: AppColors.subtle(context)),
                ),
              ),
              if (names.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                  child: Text('No folders yet.'),
                )
              else
                ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  // The index AFTER the lift, so there is nothing to
                  // compensate for — the deprecated onReorder is the one that
                  // needs the -1 dance, and compensating anyway swaps the
                  // wrong pair.
                  onReorderItem: folders.reorder,
                  children: [
                    for (var i = 0; i < names.length; i++)
                      _FolderRow(
                        key: ValueKey('folder_${names[i]}'),
                        name: names[i],
                        index: i,
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: Text(folders.isFull
                    ? 'Folder limit reached (${ChatFolders.maxFolders})'
                    : 'New folder'),
                enabled: !folders.isFull,
                onTap: folders.isFull ? null : () => _createFolder(context),
              ),
            ],
          );
        },
      ),
    );
  }

  static Future<void> _createFolder(BuildContext context) async {
    final name = await _askForName(context, title: 'New folder');
    if (name == null) return;
    final ok = await ChatFolders.instance.create(name);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That name is already taken.')));
    }
  }

  static Future<String?> _askForName(BuildContext context,
      {required String title, String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Save')),
        ],
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  final String name;
  final int index;
  const _FolderRow({super.key, required this.name, required this.index});

  @override
  Widget build(BuildContext context) {
    final count = ChatFolders.instance.idsIn(name).length;
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(name),
      subtitle: Text(count == 1 ? '1 chat' : '$count chats'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.more_horiz),
            tooltip: 'Rename or delete',
            onPressed: () => _menu(context),
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.only(left: 4, right: 4),
              child: Icon(Icons.drag_handle),
            ),
          ),
        ],
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _FolderChatsScreen(folder: name))),
    );
  }

  void _menu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final next = await ChatFoldersScreen._askForName(context,
                    title: 'Rename folder', initial: name);
                if (next == null) return;
                final ok = await ChatFolders.instance.rename(name, next);
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('That name is already taken.')));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete folder'),
              // Worth saying plainly: people hesitate over this exact button
              // because it reads like it might take the conversations too.
              subtitle: const Text('The chats stay, only the tab goes'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                ChatFolders.instance.delete(name);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Tick the conversations that belong in one folder.
class _FolderChatsScreen extends StatelessWidget {
  final String folder;
  const _FolderChatsScreen({required this.folder});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(folder)),
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [ChatFolders.instance, ChatStore.instance]),
        builder: (context, _) {
          // Folders are for conversations somebody keeps, so the pickable set
          // is the ordinary chat list plus the archive — never requests, and
          // never a hidden chat, which must not be listed anywhere.
          final chats = [
            ...ChatStore.instance.chats,
            ...ChatStore.instance.archivedChats,
          ];
          if (chats.isEmpty) {
            return const Center(child: Text('No chats to add yet.'));
          }
          return ListView.builder(
            itemCount: chats.length,
            itemBuilder: (context, i) {
              final chat = chats[i];
              final inIt = ChatFolders.instance.contains(folder, chat.id);
              return CheckboxListTile(
                value: inIt,
                title: Text(chat.contact.name),
                onChanged: (v) => ChatFolders.instance
                    .setInFolder(folder, chat.id, v ?? false),
              );
            },
          );
        },
      ),
    );
  }
}

/// The per-chat "Add to folder" sheet, reached from a chat's long-press menu.
Future<void> showChatFolderPicker(BuildContext context, String chatId) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListenableBuilder(
        listenable: ChatFolders.instance,
        builder: (context, _) {
          final names = ChatFolders.instance.folders;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('Add to folder',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              if (names.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: Text('No folders yet — make one below.'),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final n in names)
                      CheckboxListTile(
                        value: ChatFolders.instance.contains(n, chatId),
                        title: Text(n),
                        onChanged: (v) => ChatFolders.instance
                            .setInFolder(n, chatId, v ?? false),
                      ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: Text(ChatFolders.instance.isFull
                    ? 'Folder limit reached (${ChatFolders.maxFolders})'
                    : 'New folder'),
                enabled: !ChatFolders.instance.isFull,
                onTap: ChatFolders.instance.isFull
                    ? null
                    : () async {
                        final name = await ChatFoldersScreen._askForName(
                            context,
                            title: 'New folder');
                        if (name == null) return;
                        if (await ChatFolders.instance.create(name)) {
                          await ChatFolders.instance
                              .setInFolder(name, chatId, true);
                        }
                      },
              ),
            ],
          );
        },
      ),
    ),
  );
}
