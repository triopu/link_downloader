import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';

Future<List<List<dynamic>>> readRowsFromFile(PlatformFile file) async {
  final bytes = file.bytes;
  if (bytes == null) {
    throw Exception('File bytes are missing.');
  }

  final extension = p.extension(file.name).toLowerCase();

  if (extension == '.csv') {
    final content = utf8.decode(bytes, allowMalformed: true);
    final converter = const CsvToListConverter();
    return converter.convert(content, shouldParseNumbers: false);
  }

  final decoder = SpreadsheetDecoder.decodeBytes(bytes, update: true);
  if (decoder.tables.isEmpty) return [];

  final firstTable = decoder.tables.values.first;
  final rows = <List<dynamic>>[];
  for (var r = 0; r < firstTable.rows.length; r++) {
    rows.add(firstTable.rows[r]);
  }
  return rows;
}
