import 'package:flutter/material.dart';

/// Real pending-authorization dialog carrying the five FF002 stable
/// identifiers (ValueKey + Semantics, same _StableAnchor pattern as main.dart).
class AuthDialog extends StatelessWidget {
  const AuthDialog({
    super.key,
    required this.clientLabel,
    required this.requestId,
    required this.onApprove,
    required this.onDeny,
  });

  final String? clientLabel;
  final String? requestId;
  final Future<void> Function() onApprove;
  final Future<void> Function() onDeny;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const _DialogAnchor(
        identifier: 'acceptance.auth_dialog.title',
        child: Text('Authorization request'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _DialogAnchor(
            identifier: 'acceptance.auth_dialog.client_label',
            child: Text(
              (clientLabel ?? 'Waiting for client') +
                  (requestId == null ? '' : ' ($requestId)'),
            ),
          ),
        ],
      ),
      // AlertDialog actions are laid out in one row: approve and deny are
      // always both visible together, never scrolled or paginated.
      actions: <Widget>[
        _DialogAnchor(
          identifier: 'acceptance.auth_dialog.deny_button',
          child: TextButton.icon(
            onPressed: () => _act(context, onDeny),
            icon: const Icon(Icons.block),
            label: const Text('Deny'),
          ),
        ),
        _DialogAnchor(
          identifier: 'acceptance.auth_dialog.approve_button',
          child: FilledButton.icon(
            onPressed: () => _act(context, onApprove),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Approve'),
          ),
        ),
      ],
    );
  }

  Future<void> _act(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    final navigator = Navigator.of(context);
    await action();
    if (navigator.canPop()) {
      navigator.pop();
    }
  }
}

/// The dialog root anchor wraps the whole AlertDialog content; exposed as a
/// KeyedSubtree around the dialog when shown via [showAuthDialog].
class _DialogAnchor extends StatelessWidget {
  const _DialogAnchor({required this.identifier, required this.child});

  final String identifier;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: identifier,
      child: KeyedSubtree(
        key: ValueKey<String>(identifier),
        child: child,
      ),
    );
  }
}

/// Shows [AuthDialog] as a modal dialog rooted at the
/// `acceptance.auth_dialog.root` stable identifier.
Future<void> showAuthDialog(
  BuildContext context, {
  required String? clientLabel,
  required String? requestId,
  required Future<void> Function() onApprove,
  required Future<void> Function() onDeny,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _DialogAnchor(
      identifier: 'acceptance.auth_dialog.root',
      child: AuthDialog(
        clientLabel: clientLabel,
        requestId: requestId,
        onApprove: onApprove,
        onDeny: onDeny,
      ),
    ),
  );
}
