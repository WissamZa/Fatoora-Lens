import 'package:flutter/material.dart';

import 'app.dart';
import 'data/database_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = DatabaseService();
  await database.initialize();
  runApp(ZakatInvoiceApp(database: database));
}
