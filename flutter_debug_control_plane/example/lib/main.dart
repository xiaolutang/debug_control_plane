import 'dart:io' show Platform;

import 'package:debug_control_plane/debug_control_plane.dart'
    show Capability, Command, DebugEvent, Resource;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_debug_control_plane/flutter_debug_control_plane.dart';

import 'src/acceptance_controller.dart';
import 'src/acceptance_plane.dart' show AcceptanceRequestLogEntry;
import 'src/android_native_plane.dart';
import 'src/auth_dialog.dart';

/// R005-FF001 (DEC-R005-006): attach the file-backed token store at app
/// assembly time, before the plane starts and before any claim can happen,
/// so cold-restart token persistence (I2) holds on devices/simulators.
Future<void> main() async {
  // Ensure the bindings are ready for path_provider's platform channel.
  WidgetsFlutterBinding.ensureInitialized();
  final controller = createAcceptanceController();
  await controller.ensurePersistentStore();
  runApp(AcceptanceApp(controller: controller));
}

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

/// R003-FB002: page-scope demo stable identifiers (AcceptanceSpec
/// `acceptance.page_scope.*`, verbatim). All five widgets are delivered by
/// this task (contract Q2 revision — refresh_tools_button included).
const List<String> pageScopeStableIdentifiers = <String>[
  'acceptance.page_scope.open_button',
  'acceptance.page_scope.close_button',
  'acceptance.page_scope.page_id_text',
  'acceptance.page_scope.registered_count_text',
  'acceptance.page_scope.refresh_tools_button',
];

/// Demo page identities (task definition key snippet).
const String pageAId = 'page-a';
const String pageBId = 'page-b';

/// The fixed per-page capability ids both demo pages register. The same
/// capIds coexisting under different page scopes is the intended BF001
/// demonstration (contract 已知约束). Declared by [_PagePanelCapability] /
/// [_PageFormCapability] below.
const List<String> pageCapabilityIds = <String>[
  'sample.page.panel',
  'sample.page.form',
];

/// Placeholder endpoint shown before the plane is running.
const String kAcceptanceEndpointPlaceholder = 'http://127.0.0.1:0';

class AcceptanceApp extends StatelessWidget {
  const AcceptanceApp({super.key, this.controller, this.autoStart = true});

  /// Optional injected controller; when null the app creates and starts one.
  final AcceptanceController? controller;

  /// Whether the home host auto-starts the plane on first dependency change.
  /// Tests that drive start() themselves pass false to avoid a double start
  /// (the native bridge attach is one-shot — R002-FF003).
  final bool autoStart;

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
          ? _AcceptanceHomeHost(autoStart: autoStart)
          : _AcceptanceHomeHost(controller: controller, autoStart: autoStart),
    );
  }
}

/// Creates a controller, starts the plane and hosts the home page.
class _AcceptanceHomeHost extends StatefulWidget {
  const _AcceptanceHomeHost({this.controller, this.autoStart = true});

  final AcceptanceController? controller;

  final bool autoStart;

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
    if (!_started && widget.autoStart) {
      _started = true;
      _controller.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AcceptanceHomePage(
      controller: _controller,
      resolveDemoBridge: resolveDemoBridge,
    );
  }

  /// Resolves the bridge the demo pages attach to (contract KD-2).
  ///
  /// Android: reuses the host's own bridge via the new public getter — never
  /// a second instance over the same channel. Any other platform: `DartPlaneHost`
  /// holds no [NativeControlPlaneBridge], so the demo constructs a degraded
  /// bridge over a DISTINCT channel name (no handler preemption); page
  /// registration there is expected to fail and drives the demo's error path.
  NativeControlPlaneBridge? resolveDemoBridge() {
    final host = _controller.host;
    if (host is AndroidNativePlane) return host.bridge;
    return null;
  }
}

class AcceptanceHomePage extends StatelessWidget {
  const AcceptanceHomePage({
    super.key,
    required this.controller,
    this.resolveDemoBridge,
  });

  final AcceptanceController controller;

  /// R003-FB002 (KD-2): resolves the bridge the demo pages attach to.
  /// Null means non-Android mode — the page then uses its degraded
  /// demo-channel bridge and demonstrates the registration failure path.
  final NativeControlPlaneBridge? Function()? resolveDemoBridge;

  void _openDemoPage(BuildContext context, String pageId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PageScopeDemoPage(
        pageId: pageId,
        bridge: resolveDemoBridge?.call(),
      ),
    ));
  }

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
                const SizedBox(height: 12),
                _PageScopeEntrySection(
                  controller: controller,
                  onOpenPage: (pageId) => _openDemoPage(context, pageId),
                ),
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

/// R003-FB002: home entry section for the page-scope capability demo.
class _PageScopeEntrySection extends StatelessWidget {
  const _PageScopeEntrySection({
    required this.controller,
    required this.onOpenPage,
  });

  final AcceptanceController controller;

  final ValueChanged<String> onOpenPage;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Page Scope Demo',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          _ControlButton(
            identifier: 'acceptance.page_scope.open_button',
            icon: Icons.open_in_new,
            label: 'Open page A',
            onPressed: () => onOpenPage(pageAId),
          ),
          _ControlButton(
            identifier: 'acceptance.page_scope.refresh_tools_button',
            icon: Icons.refresh,
            label: 'Refresh tools',
            onPressed: controller.refreshToolList,
          ),
          OutlinedButton.icon(
            key: const ValueKey<String>('page-b-entry'),
            onPressed: () => onOpenPage(pageBId),
            icon: const Icon(Icons.layers),
            label: const Text('Open page B'),
          ),
        ],
      ),
    );
  }
}

/// R003-FB002: one demo page registering `sample.page.panel` / `sample.page.form`
/// under its own [PageCapabilityScope] on open and disposing it on close
/// (PopScope with canPop:false so BOTH the close button and the system pop
/// converge onto [_leave] — contract Q6).
class PageScopeDemoPage extends StatefulWidget {
  const PageScopeDemoPage({
    super.key,
    required this.pageId,
    required this.bridge,
  });

  final String pageId;

  /// Host bridge in Android mode; null on other platforms — the page then
  /// builds its degraded bridge over a distinct demo channel name.
  final NativeControlPlaneBridge? bridge;

  @override
  State<PageScopeDemoPage> createState() => _PageScopeDemoPageState();
}

class _PageScopeDemoPageState extends State<PageScopeDemoPage> {
  PageCapabilityScope? _scope;
  String? _errorText;

  NativeControlPlaneBridge get _effectiveBridge => widget.bridge ??
      NativeControlPlaneBridge(
        channel: const MethodChannel('debug_control_plane/page_scope_demo'),
      );

  @override
  void initState() {
    super.initState();
    _registerAll();
  }

  Future<void> _registerAll() async {
    final scope = PageCapabilityScope(
      bridge: _effectiveBridge,
      pageId: widget.pageId,
      pageName: 'Page ${widget.pageId}',
    );
    // Publish the scope synchronously so page_id/registered_count render
    // before registration resolves (fake-async safe).
    setState(() {
      _scope = scope;
    });
    String? errorText;
    try {
      await scope.registerAll(pageCapabilityIds
          .map((id) => BridgeCapability(_PageCapability(id)))
          .toList());
    } catch (error) {
      // Degraded path (non-Android) or bridge failure: surface the error,
      // count stays at whatever actually registered (0), app does not crash.
      errorText = '$error';
    }
    if (!mounted || !identical(scope, _scope)) return;
    setState(() {
      _errorText = errorText;
    });
    if (mounted && identical(scope, _scope)) setState(() {});
  }

  /// The single exit path (KD-2/Q6): await scoped dispose, then pop.
  Future<void> _leave() async {
    final scope = _scope;
    if (scope != null) {
      await scope.dispose();
      if (!mounted || !identical(scope, _scope)) return;
      setState(() => _scope = null);
    }
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    final count = scope?.registeredCount ?? 0;
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: Text('Page Scope Demo')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              _Section(
                title: 'Capabilities',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _MetricRow(
                      label: 'Page',
                      child: _StableAnchor(
                        identifier:
                            'acceptance.page_scope.page_id_text',
                        child: SelectableText(widget.pageId),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _MetricRow(
                      label: 'Registered',
                      child: _StableAnchor(
                        identifier:
                            'acceptance.page_scope.registered_count_text',
                        child: Text('$count registered'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_errorText != null)
                      Text(
                        _errorText!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _StableAnchor(
                identifier: 'acceptance.page_scope.close_button',
                child: FilledButton.icon(
                  onPressed: _leave,
                  icon: const Icon(Icons.close),
                  label: const Text('Close page'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Safety net for teardown paths that bypass _leave (e.g. test harness);
    // dispose is idempotent.
    _scope?.dispose();
    super.dispose();
  }
}

/// Minimal placeholder page capability for the demo pages. One class covers
/// both `sample.page.panel` / `sample.page.form` ([pageCapabilityIds]) — the
/// two placeholders differ only in id / resource path / state key.
class _PageCapability implements Capability {
  const _PageCapability(this.capId);

  final String capId;

  @override
  String get id => capId;

  /// `sample.page.panel` → panel / `sample.page.form` → form.
  String get _kind => capId.split('.').last;

  @override
  List<Resource> get resources => <Resource>[
        Resource(
          method: 'GET',
          path: ['pages', _kind],
          description: 'demo page $_kind state',
          handler: (ctx) async => {'page': _kind},
        ),
      ];

  @override
  List<Command> get commands => <Command>[];

  @override
  Map<String, Object?> state() => <String, Object?>{_kind: true};

  @override
  Stream<DebugEvent> get events => const Stream<DebugEvent>.empty();
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
