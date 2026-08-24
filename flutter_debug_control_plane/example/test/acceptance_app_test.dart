import 'package:debug_control_plane_acceptance_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AcceptanceApp skeleton', () {
    testWidgets('renders Status, Requests and Controls sections',
        (WidgetTester tester) async {
      await tester.pumpWidget(const AcceptanceApp());

      expect(find.text('Status'), findsOneWidget);
      expect(find.text('Requests'), findsOneWidget);
      expect(find.text('Controls'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('exposes every stable identifier', (WidgetTester tester) async {
      await tester.pumpWidget(const AcceptanceApp());

      for (final identifier in acceptanceStableIdentifiers) {
        expect(
          find.byKey(ValueKey<String>(identifier)),
          findsOneWidget,
          reason: 'Missing stable identifier: $identifier',
        );
      }
    });

    testWidgets('placeholder controls are tappable without exceptions',
        (WidgetTester tester) async {
      await tester.pumpWidget(const AcceptanceApp());

      await tester.tap(find.byKey(
        const ValueKey<String>('acceptance.controls.clear_token_button'),
      ));
      await tester.pump();
      await tester.tap(find.byKey(
        const ValueKey<String>('acceptance.controls.expire_token_button'),
      ));
      await tester.pump();
      await tester.ensureVisible(find.byKey(
        const ValueKey<String>('acceptance.auth_dialog.approve_button'),
      ));
      await tester.pump();
      await tester.tap(find.byKey(
        const ValueKey<String>('acceptance.auth_dialog.approve_button'),
      ));
      await tester.pump();
      await tester.ensureVisible(find.byKey(
        const ValueKey<String>('acceptance.auth_dialog.deny_button'),
      ));
      await tester.pump();
      await tester.tap(find.byKey(
        const ValueKey<String>('acceptance.auth_dialog.deny_button'),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('placeholder state text is internally consistent',
        (WidgetTester tester) async {
      await tester.pumpWidget(const AcceptanceApp());

      expect(find.text('http://127.0.0.1:0'), findsOneWidget);
      expect(find.text('authorization_required'), findsOneWidget);
      expect(find.text('4 registered'), findsOneWidget);
      expect(find.text('No requests yet'), findsOneWidget);
      expect(
          find.text('allowed / rejected / expired / denied'), findsOneWidget);
    });
  });
}
