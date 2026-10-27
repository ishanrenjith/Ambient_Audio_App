import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Requests RECORD_AUDIO permission and returns true if granted.
Future<bool> requestMicrophonePermission(BuildContext context) async {
  // Directly request — this always triggers the system dialog on first run.
  final status = await Permission.microphone.request();

  if (status.isGranted) return true;

  if (status.isPermanentlyDenied) {
    // User tapped "Don't ask again" — send them to Settings.
    if (context.mounted) {
      await _showSettingsDialog(context);
    }
    return false;
  }

  // Denied but not permanently — show a rationale.
  if (context.mounted) {
    await _showRationaleDialog(context);
  }
  return false;
}

Future<void> _showRationaleDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Microphone required'),
      content: const Text(
        'Ambient Audio needs microphone access to detect when you '
            'speak. Without it, the app cannot reduce media volume during conversations.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<void> _showSettingsDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Permission permanently denied'),
      content: const Text(
        'Microphone access has been permanently denied. '
            'Please enable it in your device settings to use this app.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            openAppSettings();
            Navigator.pop(ctx);
          },
          child: const Text('Open Settings'),
        ),
      ],
    ),
  );
}