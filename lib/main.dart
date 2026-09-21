import 'package:flutter/material.dart';

import 'app.dart';
import 'data/database_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = DatabaseService();
  Object? startupError;
  StackTrace? startupStack;
  try {
    await database.initialize();
  } catch (error, stackTrace) {
    startupError = error;
    startupStack = stackTrace;
  }

  runApp(
    startupError == null
        ? FatooraLensApp(database: database)
        : StartupErrorApp(error: startupError, stackTrace: startupStack),
  );
}
