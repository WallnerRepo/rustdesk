import 'package:flutter/material.dart';

import 'herdr_relay_client.dart';

/// Rename prompt shared by the home page and the agent page. Validates the
/// name against the relay's own pattern (see herdrAgentNameError) before
/// returning it, so the user never gets a raw relay error back. Returns null
/// when cancelled.
Future<String?> showHerdrRenameDialog(BuildContext context, String current) {
  return showDialog<String>(
    context: context,
    builder: (context) => _HerdrRenameDialog(current: current),
  );
}

class _HerdrRenameDialog extends StatefulWidget {
  const _HerdrRenameDialog({required this.current});

  final String current;

  @override
  State<_HerdrRenameDialog> createState() => _HerdrRenameDialogState();
}

class _HerdrRenameDialogState extends State<_HerdrRenameDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.current);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    final error = herdrAgentNameError(name);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Renombrar agente'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Nombre',
          hintText: 'mi-agente',
          helperText: 'Minúsculas, números, "-" y "_"',
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
        textInputAction: TextInputAction.done,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
