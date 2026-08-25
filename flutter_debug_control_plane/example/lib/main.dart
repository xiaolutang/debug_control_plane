import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'src/acceptance_controller.dart';
import 'src/acceptance_plane.dart' show AcceptanceRequestLogEntry;
import 'src/android_native_plane.dart';
import 'src/auth_dialog.dart';

void main() => runApp(const AcceptanceApp());

/// Plane mode selection (DEC-R002-005): Android devices run the debug plane
/// in the native process via the plugin bridge; everywhere else (iOS
/// simulator etc.) the Dart plane keeps FB001 behavior.
AcceptanceController createAcceptanceController() {
  if (Platform.isAndroid) {
    return AcceptanceController.withHost(AndroidNativePlane());
  }
  return AcceptanceController();
}

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

/// Placeholder endpoint shown before the plane is running.
const String kAcceptanceEndpointPlaceholder = 'http://127.0.0.1:0';

class AcceptanceApp extends StatelessWidget {
  const AcceptanceApp({super.key, this.controller});

  /// Optional injected controller; when null the app creates and starts one.
  final AcceptanceController? controller;

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
      home: controller == null
          ? const _AcceptanceHomeHost()
          : _AcceptanceHomeHost(controller: controller),
    );
  }
}

/// Creates a controller, starts the plane and hosts the home page.
class _AcceptanceHomeHost extends StatefulWidget {
  const _AcceptanceHomeHost({this.controller});

  final AcceptanceController? controller;

  @override
  State<_AcceptanceHomeHost> createState() => _AcceptanceHomeHostState();
}

class _AcceptanceHomeHostState extends State<_AcceptanceHomeHost> {
  AcceptanceController? _ownedController;
  bool _started = false;
  bool _dialogShowing = false;

  AcceptanceController get _controller =>
      widget.controller ?? _ownedController!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ownedController = createAcceptanceController();
    }
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _ownedController?.dispose();
    super.dispose();
  }

  /// Shows the pending auth dialog whenever authState == pending
  /// (interaction assertion: dialog visible ⇔ authStatus == "pending").
  void _onControllerChanged() {
    final pending = _controller.authState == AcceptanceAuthState.pending;
    if (pending &&
        !_dialogShowing &&
        mounted &&
        ModalRoute.of(context)?.isCurrent != false) {
      _dialogShowing = true;
      showAuthDialog(
        context,
        clientLabel: _controller.pendingClientLabel,
        requestId: _controller.pendingRequestId,
        onApprove: _controller.approvePending,
        onDeny: _controller.denyPending,
      ).whenComplete(() => _dialogShowing = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AcceptanceHomePage(controller: _controller);
  }
}

class AcceptanceHomePage extends StatelessWidget {
  const AcceptanceHomePage({super.key, required this.controller});

  final AcceptanceController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Debug Plane Acceptance'),
        centerTitle: false,
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: <Widget>[
                _StatusSection(
                  endpoint: controller.endpoint?.toString() ??
                      kAcceptanceEndpointPlaceholder,
                  authState: controller.authState.name,
                  capabilityCount: controller.capabilityCount,
                ),
                const SizedBox(height: 12),
                _RequestsSection(controller: controller),
                const SizedBox(height: 12),
                _ControlsSection(controller: controller),
              ],
            );
          },
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
  const _RequestsSection({required this.controller});

  final AcceptanceController controller;

  @override
  Widget build(BuildContext context) {
    final entries = controller.requestLog;
    return _Section(
      title: 'Requests',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _StableAnchor(
            identifier: 'acceptance.requests.last_result_text',
            child: Text(controller.lastResultText),
          ),
          const SizedBox(height: 10),
          _StableAnchor(
            identifier: 'acceptance.requests.list',
            child: entries.isEmpty
                ? const _RequestListEmpty()
                : _RequestList(entries: entries),
          ),
        ],
      ),
    );
  }
}

class _RequestListEmpty extends StatelessWidget {
  const _RequestListEmpty();

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

class _RequestList extends StatelessWidget {
  const _RequestList({required this.entries});

  final List<AcceptanceRequestLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final entry in entries)
            Text(
              '${entry.method} ${entry.route} '
              '${entry.statusCode} ${entry.authResult}',
              key: ValueKey<int>(entry.sequence),
            ),
        ],
      ),
    );
  }
}

class _ControlsSection extends StatelessWidget {
  const _ControlsSection({required this.controller});

  final AcceptanceController controller;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Controls',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _ControlButton(
                identifier: 'acceptance.controls.clear_token_button',
                icon: Icons.delete_outline,
                label: 'Clear token',
                onPressed: () => controller.clearToken(),
              ),
              _ControlButton(
                identifier: 'acceptance.controls.expire_token_button',
                icon: Icons.schedule,
                label: 'Expire token',
                onPressed: controller.canExpireToken
                    ? () => controller.expireToken()
                    : null,
              ),
            ],
          ),
        ],
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

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.identifier,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final String identifier;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return _StableAnchor(
      identifier: identifier,
      child: OutlinedButton.icon(
        onPressed: onPressed,
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
