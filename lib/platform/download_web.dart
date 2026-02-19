// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:dio/dio.dart';

typedef ProgressCallback = void Function(int received, int total);

typedef BytesDownloader = Future<List<int>> Function();

Future<void> downloadFile({
  required Dio dio,
  required String url,
  required String fileName,
  required String? folderPath,
  required ProgressCallback onProgress,
}) async {
  final bytes = await fetchBytes(
    dio: dio,
    url: url,
    onProgress: onProgress,
  );

  await saveBytes(fileName: fileName, bytes: bytes);
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
}) async {
  final blob = html.Blob([bytes]);
  final objectUrl = html.Url.createObjectUrlFromBlob(blob);

  final anchor = html.AnchorElement(href: objectUrl)
    ..download = fileName
    ..style.display = 'none';

  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(objectUrl);
}
