import 'package:flutter_test/flutter_test.dart';

Future<void> tapJourney(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> enterSelection(WidgetTester tester) async {
  if (find.text('Add books').evaluate().isNotEmpty ||
      find.text('Добавить книги').evaluate().isNotEmpty) {
    return;
  }
  if (find.text('Confirm reader').evaluate().isNotEmpty) {
    await tapJourney(tester, 'Confirm reader');
  } else if (find.text('Подтвердить ридер').evaluate().isNotEmpty) {
    await tapJourney(tester, 'Подтвердить ридер');
  }
  final english = find.text('Choose books');
  await tapJourney(
    tester,
    english.evaluate().isNotEmpty ? 'Choose books' : 'Выбрать книги',
  );
}
