import 'package:flutter_test/flutter_test.dart';
import 'package:terra_twin/main.dart';

void main() {
  testWidgets('Home screen shows headline', (WidgetTester tester) async {
    await tester.pumpWidget(const GeoXApp());

    expect(find.text('EARTH IS\nBECOMING\nMORE ALIEN.'), findsOneWidget);
    expect(find.text('EXPLORE PLANETARY ANALOGUES →'), findsOneWidget);
  });
}
