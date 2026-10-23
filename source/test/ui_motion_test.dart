import 'package:brizfi/ui/brizfi_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child, {bool reduced = false}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Align(alignment: Alignment.topLeft, child: child),
    ),
  );

  testWidgets('height changes gradually with the top edge anchored', (
    tester,
  ) async {
    Widget content(double height) =>
        host(BrizfiMotionSize(child: SizedBox(width: 200, height: height)));
    await tester.pumpWidget(content(200));
    final motion = find.byType(AnimatedSize);
    final top = tester.getTopLeft(motion);
    await tester.pumpWidget(content(80));
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getSize(motion).height, greaterThan(80));
    expect(tester.getSize(motion).height, lessThan(200));
    expect(tester.getTopLeft(motion), top);
    // A second update during the transition still reaches the latest size.
    await tester.pumpWidget(content(120));
    await tester.pumpAndSettle();
    expect(tester.getSize(motion).height, 120);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inserted content fades once without replaying on rebuild', (
    tester,
  ) async {
    Widget content(String label) => host(BrizfiFadeIn(child: Text(label)));
    await tester.pumpWidget(content('first'));
    final opacity = find.descendant(
      of: find.byType(BrizfiFadeIn),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(opacity).opacity, 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.widget<Opacity>(opacity).opacity, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    await tester.pumpWidget(content('updated'));
    expect(tester.widget<Opacity>(opacity).opacity, 1);
  });

  testWidgets('reduced motion changes size immediately without a fade', (
    tester,
  ) async {
    Widget content(double height) => host(
      BrizfiFadeIn(
        child: BrizfiMotionSize(
          child: SizedBox(
            key: const ValueKey('content'),
            width: 200,
            height: height,
          ),
        ),
      ),
      reduced: true,
    );
    await tester.pumpWidget(content(200));
    await tester.pumpWidget(content(80));
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey('content'))).height, 80);
    expect(find.byType(AnimatedSize), findsNothing);
    expect(
      find.descendant(
        of: find.byType(BrizfiFadeIn),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
