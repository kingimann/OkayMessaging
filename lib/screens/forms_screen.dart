import 'package:flutter/material.dart';

import '../models/form_spec.dart';
import '../state/saved_forms.dart';
import '../theme/app_theme.dart';
import 'form_builder_screen.dart';
import 'home_screen.dart';

/// The forms this account has built, to use again.
///
/// A form used to exist only as a message: the builder opened blank from a
/// chat's attachment panel, the questions went out, and nobody saw them
/// again — so the same RSVP got rebuilt from scratch every month. This is
/// where they live between sendings, and the only place they can be EDITED
/// at all.
///
/// **It does not send.** Sending needs a conversation, and picking one from
/// here would be a second, worse chat picker beside the one every share
/// already uses; the attachment panel offers the saved forms at the moment
/// somebody is actually in a chat, which is where the choice belongs. This
/// screen builds, edits and deletes.
class FormsScreen extends StatelessWidget {
  const FormsScreen({super.key, this.fromSidebar = false});

  /// Carried like every other sidebar destination. The leading is a normal
  /// back arrow either way (the 2026-08-09 navigation decision); the flag is
  /// kept so the call sites stay uniform.
  final bool fromSidebar;

  Future<void> _edit(BuildContext context, {SavedForm? existing}) async {
    final result = await Navigator.of(context)
        .push<(String, List<FormFieldSpec>, ({bool anonymous}))>(
      MaterialPageRoute(
        builder: (_) => FormBuilderScreen(
          initialTitle: existing?.title ?? '',
          initialFields: existing?.fields ?? const [],
          initialAnonymous: existing?.anonymous ?? false,
          title: existing == null ? 'New form' : 'Edit form',
          submitLabel: 'Save',
        ),
      ),
    );
    if (result == null) return;
    SavedForms.instance.save(
        id: existing?.id,
        title: result.$1,
        fields: result.$2,
        anonymous: result.$3.anonymous);
  }

  Future<void> _delete(BuildContext context, SavedForm form) async {
    final messenger = ScaffoldMessenger.of(context);
    final gone = SavedForms.instance.remove(form.id);
    if (gone == null) return;
    // An undo rather than a confirm dialog: this is the person's own work,
    // and a form is cheap to put back and expensive to retype.
    messenger.showSnackBar(SnackBar(
      content: Text('Deleted "${gone.title}"'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => SavedForms.instance.restore(gone),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      appBar: AppBar(
        title: const Text('Forms'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New form',
            onPressed: () => _edit(context),
          ),
        ],
      ),
      bottomNavigationBar: const HomeNavBar(),
      body: ListenableBuilder(
        listenable: SavedForms.instance,
        builder: (context, _) {
          final forms = SavedForms.instance.forms;
          if (forms.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.assignment_outlined,
                        size: 40, color: AppColors.subtle(context)),
                    const SizedBox(height: 12),
                    Text(
                      'No saved forms yet. Build one here and it is waiting '
                      'in a chat’s attachment panel the next time you '
                      'need to ask the same thing.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.subtle(context)),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => _edit(context),
                      icon: const Icon(Icons.add),
                      label: const Text('New form'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView(
            padding: EdgeInsets.only(bottom: HomeNavBar.clearance(context)),
            children: [
              for (final form in forms)
                ListTile(
                  leading: const Icon(Icons.assignment_outlined),
                  title: Text(form.title.isEmpty ? 'Untitled form' : form.title,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(form.summary),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    onPressed: () => _delete(context, form),
                  ),
                  onTap: () => _edit(context, existing: form),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  'Saved on this device only — never on a server, and '
                  'not in the encrypted backup. Send one from a chat’s '
                  'attachment panel.',
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.subtle(context)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
