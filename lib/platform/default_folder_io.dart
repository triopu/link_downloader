import 'dart:io';

import 'package:path/path.dart' as p;

Future<String?> getDefaultDownloadFolder() async {
  String? homePath;
  if (Platform.isWindows) {
    homePath = Platform.environment['USERPROFILE'];
  } else if (Platform.isMacOS || Platform.isLinux) {
    homePath = Platform.environment['HOME'];
  }
  if (homePath == null || homePath.isEmpty) return null;

  final downloadPath = p.join(homePath, 'Downloads');
  final directory = Directory(downloadPath);
  if (await directory.exists()) {
    return downloadPath;
  }

  return null;
}
