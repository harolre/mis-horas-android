import 'package:flutter_test/flutter_test.dart';
import 'package:mis_horas/main.dart';

void main() {
  testWidgets('muestra la pantalla inicial de Mis Horas', (tester) async {
    await tester.pumpWidget(const MisHorasApp());
    await tester.pumpAndSettle();

    expect(find.text('Mis Horas'), findsOneWidget);
    expect(find.text('Flutter Demo'), findsNothing);
  });
}
