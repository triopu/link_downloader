import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

typedef ProgressCallback = void Function(int received, int total);

typedef BytesDownloader = Future<List<int>> Function();

Future<void> downloadFile({
  required Dio dio,
  required String url,
  required String fileName,
  required String? folderPath,
  required ProgressCallback onProgress,
}) async {
  if (folderPath == null || folderPath.isEmpty) {
    throw Exception('No download folder selected.');
  }

  final outputPath = p.join(folderPath, fileName);
  await dio.download(
    url,
    outputPath,
    onReceiveProgress: onProgress,
    options: Options(
      responseType: ResponseType.bytes,
      followRedirects: true,
      receiveTimeout: const Duration(minutes: 5),
    ),
  );
}

Future<List<int>> fetchBytes({
  required Dio dio,
  required String url,
  required ProgressCallback onProgress,
}) async {
  final response = await dio.get<List<int>>(
    url,
    options: Options(
      responseType: ResponseType.bytes,
      followRedirects: true,
    ),
    onReceiveProgress: onProgress,
  );

  return response.data ?? <int>[];
}

Future<void> saveBytes({
  required String fileName,
  required List<int> bytes,
  String? folderPath,
}) async {
  if (folderPath == null || folderPath.isEmpty) {
    throw Exception('No download folder selected.');
  }

  final outputPath = p.join(folderPath, fileName);
  final file = File(outputPath);
  await file.writeAsBytes(bytes, flush: true);
}
