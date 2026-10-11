import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/features/shiv/gana/engine/gana_engine_test.dart' as gana_tests;

/// Runs the isolated Gana routing cases with the app installed on a device.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('mobile Gana routing', () {
    gana_tests.main(routingMatrixOnly: true);
  });
}
