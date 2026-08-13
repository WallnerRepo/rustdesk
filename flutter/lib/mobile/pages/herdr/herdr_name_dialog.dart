import 'package:flutter/material.dart';

/// Rename prompt shared by the home page and the agent page. Returns null
/// when cancelled.
///
/// This renames the agent's TAB LABEL, not the agent. Relay 0.14.10 re-pointed
/// `agent_rename` at herdr's tab-label op and dropped the name pattern with
/// it, so anything non-empty is accepted here — spaces and capitals included.
/// The pattern still guards agent *creation* (`lifecycle.go` agentNamePattern),
/// which is why [herdrAgentNameError] is still applied there and not here.
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
    if (name.isEmpty) {
      setState(() => _error = 'No puede estar vacío');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Renombrar pestaña'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Etiqueta',
          hintText: 'mi pestaña',
          helperText: 'Cualquier texto; cambia la etiqueta, no el agente',
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
