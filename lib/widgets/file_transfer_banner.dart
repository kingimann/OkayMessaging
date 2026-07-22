import 'dart:async';

import 'package:flutter/material.dart';

import '../state/file_transfer.dart';
import '../theme/app_theme.dart';

/// A bottom banner shown while a peer-to-peer file transfer is active:
/// an incoming offer (Accept / Decline), a live progress bar, or a brief
/// terminal state. Rendered above the whole app by the root overlay.
class FileTransferBanner extends StatefulWidget {
  const FileTransferBanner({super.key});

  @override
  State<FileTransferBanner> createState() => _FileTransferBannerState();
}

class _FileTransferBannerState extends State<FileTransferBanner> {
  Timer? _dismiss;

  @override
  void initState() {
    super.initState();
    FileTransfer.instance.current.addListener(_onChange);
  }

  void _onChange() {
    final s = FileTransfer.instance.current.value;
    if (s != null &&
        (s.status == 'done' ||
            s.status == 'declined' ||
            s.status == 'failed')) {
      _dismiss ??= Timer(const Duration(milliseconds: 2600), () {
        FileTransfer.instance.clear();
        _dismiss = null;
      });
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _dismiss?.cancel();
    FileTransfer.instance.current.removeListener(_onChange);
    super.dispose();
  }

  String _size(int bytes) {
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final s = FileTransfer.instance.current.value;
    if (s == null) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget body;
    if (s.incoming && s.status == 'offering') {
      body = Row(
        children: [
          const Icon(Icons.attach_file, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${s.peerName} is sending ${s.fileName} (${_size(s.total)})',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => FileTransfer.instance.decline(),
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: () => FileTransfer.instance.accept(),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.tealGreenDark,
            ),
            child: const Text('Accept'),
          ),
        ],
      );
    } else if (s.status == 'transferring' || s.status == 'offering') {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.attach_file, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${s.incoming ? 'Receiving' : 'Sending'} ${s.fileName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${(s.progress * 100).round()}%'),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: s.status == 'offering' ? null : s.progress,
              minHeight: 5,
              backgroundColor: Colors.grey.withValues(alpha: 0.25),
              color: AppColors.tealGreenDark,
            ),
          ),
        ],
      );
    } else {
      final label = switch (s.status) {
        'done' => s.incoming
            ? '✓ Downloaded ${s.fileName}'
            : '✓ Sent ${s.fileName}',
        'declined' => 'File declined',
        _ => 'Transfer failed',
      };
      body = Row(children: [
        Icon(s.status == 'done' ? Icons.check_circle : Icons.error_outline,
            size: 20,
            color: s.status == 'done' ? Colors.green : Colors.red),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
      ]);
    }

    return Positioned(
      left: 8,
      right: 8,
      bottom: 8,
      child: SafeArea(
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(14),
          color: isDark ? const Color(0xFF23262B) : Colors.white,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: body,
          ),
        ),
      ),
    );
  }
}
