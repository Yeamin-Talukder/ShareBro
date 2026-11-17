import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where ShareBro keeps its own data (database, thumbnail cache, chip
/// timings). Normally the app-support folder; tests that run the real app
/// pass `--dart-define=SB_DATA_DIR=<scratch folder>` so they never touch
/// the data of the person using it.
const dataDirOverride = String.fromEnvironment('SB_DATA_DIR');

Future<Directory> appDataDir() async =>
    dataDirOverride.isNotEmpty ? Directory(dataDirOverride).create(recursive: true) : getApplicationSupportDirectory();
