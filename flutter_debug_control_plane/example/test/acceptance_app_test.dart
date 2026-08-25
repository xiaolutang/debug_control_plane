import 'package:debug_control_plane_acceptance_example/main.dart';
import 'package:debug_control_plane_acceptance_example/src/acceptance_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real plane I/O must run inside tester.runAsync; afterwards a plain pump
/// rebuilds the widgets bound to the controller.
Future<void> runReal(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  await tester.runAsync(action);
  await tester.pump();
}

void main() {
  group('AcceptanceApp skeleton', () {
    testWidgets('renders Status, Requests and Controls sections',
        (WidgetTester tester) async {
      final controller = AcceptanceController();
      await tester.pumpWidget(AcceptanceApp(controller: controller));
      await tester.pump();

      expect(find.text('Status'), findsOneWidget);
      expect(find.text('Requests'), findsOneWidget);
      expect(find.text('Controls'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);

      await runReal(tester, controller.stop);
      controller.dispose();
    });

    testWidgets('exposes all non-dialog stable identifiers before pending',
        (WidgetTester tester) async {
      final controller = AcceptanceController();
      await tester.pumpWidget(AcceptanceApp(controller: controller));
      await tester.pump();

      const dialogIds = <String>{
        'acceptance.auth_dialog.root',
        'acceptance.auth_dialog.title',
        'acceptance.auth_dialog.client_label',
        'acceptance.auth_dialog.approve_button',
        'acceptance.auth_dialog.deny_button',
      };
      for (final identifier in acceptanceStableIdentifiers) {
        if (dialogIds.contains(identifier)) continue;
        expect(
          find.byKey(ValueKey<String>(identifier)),
          findsOneWidget,
          reason: 'Missing stable identifier: $identifier',
        );
      }

      await runReal(tester, controller.stop);
      controller.dispose();
    });

    testWidgets('all 12 stable identifiers present once pending dialog shows',
        (WidgetTester tester) async {
      final controller = AcceptanceController();
      await tester.pumpWidget(AcceptanceApp(controller: controller));
      await tester.pump();

      await runReal(
        tester,
        () => controller.simulateAuthRequest(clientLabel: 'desktop-cli'),
      );

      for (final identifier in acceptanceStableIdentifiers) {
        expect(
          find.byKey(ValueKey<String>(identifier)),
          findsOneWidget,
          reason: 'Missing stable identifier: $identifier',
        );
      }
      expect(controller.authState, AcceptanceAuthState.pending);

      await runReal(tester, controller.stop);
      controller.dispose();
    });

    testWidgets('idle placeholder state text is internally consistent',
        (WidgetTester tester) async {
      final controller = AcceptanceController();
      await tester.pumpWidget(AcceptanceApp(controller: controller));
      await tester.pump();

      // The host starts the plane automatically; before any auth request the
      // state stays idle with the placeholder/real endpoint visible.
      expect(find.text('idle'), findsOneWidget);
      expect(find.text('4 registered'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('acceptance.status.endpoint_text')),
        findsOneWidget,
      );

      await runReal(tester, controller.stop);
      controller.dispose();
    });

    testWidgets('pending shows auth dialog; approve closes and sets approved',
        (WidgetTester tester) async {
      final controller = AcceptanceController();
      await tester.pumpWidget(AcceptanceApp(controller: controller));
      await tester.pump();

      await runReal(
        tester,
        () => controller.simulateAuthRequest(clientLabel: 'desktop-cli'),
      );

      // Dialog visible with all five identifiers.
      expect(
        find.byKey(const ValueKey<String>('acceptance.auth_dialog.root')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('acceptance.auth_dialog.title')),
        findsOneWidget,
      );
      expect(
        find.byKey(
            const ValueKey<String>('acceptance.auth_dialog.client_label')),
        findsOneWidget,
      );
      expect(find.textContaining('desktop-cli'), findsOneWidget);
      expect(controller.authState, AcceptanceAuthState.pending);

      final approveButton = find.byKey(
        const ValueKey<String>('acceptance.auth_dialog.approve_button'),
      );
      final denyButton = find.byKey(
        const ValueKey<String>('acceptance.auth_dialog.deny_button'),
      );
      // Both buttons rendered in the same dialog actions row.
      expect(approveButton, findsOneWidget);
      expect(denyButton, findsOneWidget);

      await tester.tap(approveButton);
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('acceptance.auth_dialog.root')),
        findsNothing,
      );
      expect(controller.authState, AcceptanceAuthState.approved);
      expect(
        find.descendant(
          of: find.byKey(
              const ValueKey<String>('acceptance.status.auth_state_text')),
          matching: find.text('approved'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await runReal(tester, controller.stop);
      controller.dispose();
    });

    testWidgets('deny closes dialog and sets denied', (WidgetTester tester) async {
      final controller = AcceptanceController();
      await tester.pumpWidget(AcceptanceApp(controller: controller));
      await tester.pump();

      await runReal(
        tester,
        () => controller.simulateAuthRequest(clientLabel: 'desktop-cli'),
      );

      await tester.tap(find.byKey(
        const ValueKey<String>('acceptance.auth_dialog.deny_button'),
      ));
      await tester.pump();
      await tester.pump();

      expect(controller.authState, AcceptanceAuthState.denied);
      expect(
        find.descendant(
          of: find.byKey(
              const ValueKey<String>('acceptance.status.auth_state_text')),
          matching: find.text('denied'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await runReal(tester, controller.stop);
      controller.dispose();
    });

    testWidgets('controls tap without exceptions and update state',
        (WidgetTester tester) async {
      final controller = AcceptanceController();
      await tester.pumpWidget(AcceptanceApp(controller: controller));
      await tester.pump();

      await tester.tap(find.byKey(
        const ValueKey<String>('acceptance.controls.clear_token_button'),
      ));
      await tester.pump();
      expect(controller.tokenPresent, isFalse);
      expect(controller.authState, AcceptanceAuthState.cleared);

      await tester.tap(find.byKey(
        const ValueKey<String>('acceptance.controls.expire_token_button'),
      ));
      await tester.pump();
      expect(controller.authState, AcceptanceAuthState.expired);

      expect(tester.takeException(), isNull);

      await runReal(tester, controller.stop);
      controller.dispose();
    });
  });
}
