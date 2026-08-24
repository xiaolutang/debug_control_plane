import 'package:flutter/material.dart';

void main() => runApp(const AcceptanceApp());

const List<String> acceptanceStableIdentifiers = <String>[
  'acceptance.status.endpoint_text',
  'acceptance.status.auth_state_text',
  'acceptance.status.capability_count_text',
  'acceptance.requests.list',
  'acceptance.requests.last_result_text',
  'acceptance.controls.clear_token_button',
  'acceptance.controls.expire_token_button',
  'acceptance.auth_dialog.root',
  'acceptance.auth_dialog.title',
  'acceptance.auth_dialog.client_label',
  'acceptance.auth_dialog.approve_button',
  'acceptance.auth_dialog.deny_button',
];

class AcceptanceApp extends StatelessWidget {
  const AcceptanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Debug Plane Acceptance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const AcceptanceHomePage(),
    );
  }
}

class AcceptanceHomePage extends StatelessWidget {
  const AcceptanceHomePage({super.key});

  static const String _endpoint = 'http://127.0.0.1:0';
  static const String _authState = 'authorization_required';
  static const int _capabilityCount = 4;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        title: const Text('Debug Plane Acceptance'),
        centerTitle: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: const <Widget>[
            _StatusSection(
              endpoint: _endpoint,
              authState: _authState,
              capabilityCount: _capabilityCount,
            ),
            SizedBox(height: 12),
            _RequestsSection(),
            SizedBox(height: 12),
            _ControlsSection(),
          ],
        ),
      ),
    );
  }
}

class _StatusSection extends StatelessWidget {
  const _StatusSection({
    required this.endpoint,
    required this.authState,
    required this.capabilityCount,
  });

  final String endpoint;
  final String authState;
  final int capabilityCount;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Status',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _MetricRow(
            label: 'Endpoint',
            child: _StableAnchor(
              identifier: 'acceptance.status.endpoint_text',
              child: SelectableText(
                endpoint,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _MetricRow(
            label: 'Auth',
            child: _StableAnchor(
              identifier: 'acceptance.status.auth_state_text',
              child: Text(authState),
            ),
          ),
          const SizedBox(height: 10),
          _MetricRow(
            label: 'Capabilities',
            child: _StableAnchor(
              identifier: 'acceptance.status.capability_count_text',
              child: Text('$capabilityCount registered'),
            ),
          ),
        ],
      ),
    );
  }
}

class _RequestsSection extends StatelessWidget {
  const _RequestsSection();

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Requests',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const <Widget>[
          _StableAnchor(
            identifier: 'acceptance.requests.last_result_text',
            child: Text('No requests yet'),
          ),
          SizedBox(height: 10),
          _StableAnchor(
            identifier: 'acceptance.requests.list',
            child: _RequestListPlaceholder(),
          ),
        ],
      ),
    );
  }
}

class _ControlsSection extends StatelessWidget {
  const _ControlsSection();

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Controls',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _ControlButton(
                identifier: 'acceptance.controls.clear_token_button',
                icon: Icons.delete_outline,
                label: 'Clear token',
              ),
              _ControlButton(
                identifier: 'acceptance.controls.expire_token_button',
                icon: Icons.schedule,
                label: 'Expire token',
              ),
            ],
          ),
          SizedBox(height: 12),
          _AuthDialogAnchor(),
        ],
      ),
    );
  }
}

class _AuthDialogAnchor extends StatelessWidget {
  const _AuthDialogAnchor();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _StableAnchor(
      identifier: 'acceptance.auth_dialog.root',
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            _StableAnchor(
              identifier: 'acceptance.auth_dialog.title',
              child: Text(
                'Authorization request',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            SizedBox(height: 8),
            _StableAnchor(
              identifier: 'acceptance.auth_dialog.client_label',
              child: Text('Waiting for client'),
            ),
            SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _DialogButton(
                  identifier: 'acceptance.auth_dialog.approve_button',
                  icon: Icons.check_circle_outline,
                  label: 'Approve',
                ),
                _DialogButton(
                  identifier: 'acceptance.auth_dialog.deny_button',
                  icon: Icons.block,
                  label: 'Deny',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 104,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _RequestListPlaceholder extends StatelessWidget {
  const _RequestListPlaceholder();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 56),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: const Text('allowed / rejected / expired / denied'),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.identifier,
    required this.icon,
    required this.label,
  });

  final String identifier;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return _StableAnchor(
      identifier: identifier,
      child: OutlinedButton.icon(
        onPressed: () {},
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({
    required this.identifier,
    required this.icon,
    required this.label,
  });

  final String identifier;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return _StableAnchor(
      identifier: identifier,
      child: FilledButton.tonalIcon(
        onPressed: () {},
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}

class _StableAnchor extends StatelessWidget {
  const _StableAnchor({
    required this.identifier,
    required this.child,
  });

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
