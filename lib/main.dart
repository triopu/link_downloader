import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'platform/download.dart';
import 'platform/file_reader.dart';

void main() {
  runApp(const LinkDownloaderApp());
}

class LinkDownloaderApp extends StatelessWidget {
  const LinkDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PMFTC Link Downloader',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal), useMaterial3: true),
      home: const LinkDownloaderHome(),
    );
  }
}

class LinkDownloaderHome extends StatefulWidget {
  const LinkDownloaderHome({super.key});

  @override
  State<LinkDownloaderHome> createState() => _LinkDownloaderHomeState();
}

class _LinkDownloaderHomeState extends State<LinkDownloaderHome> {
  static const String photoColumnName = 'Take a Photo';
  static const String nameColumnName = 'Name';
  static const String emailColumnName = 'E-mail';

  PlatformFile? _selectedFile;
  String? _folderPath;
  bool _isRunning = false;
  bool _zipOnWeb = false;

  int _totalCount = 0;
  int _currentIndex = 0;
  int _completedCount = 0;
  double _currentFileProgress = 0;
  String _currentFileName = '';

  final List<String> _logs = [];
  final Dio _dio = Dio();

  void _addLog(String message) {
    setState(() {
      _logs.insert(0, message);
    });
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['xlsx', 'xls', 'csv'], withData: kIsWeb);
    if (result == null || result.files.isEmpty) return;

    setState(() {
      _selectedFile = result.files.single;
    });
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null || path.isEmpty) return;

    setState(() {
      _folderPath = path;
    });
  }

  Future<void> _startDownload() async {
    if (_selectedFile == null) {
      _addLog('Please select a file first.');
      return;
    }

    if (!kIsWeb && (_folderPath == null || _folderPath!.isEmpty)) {
      _addLog('Please select a download folder.');
      return;
    }

    setState(() {
      _isRunning = true;
      _logs.clear();
      _totalCount = 0;
      _currentIndex = 0;
      _completedCount = 0;
      _currentFileProgress = 0;
      _currentFileName = '';
    });

    var completedSuccessfully = false;
    try {
      final rows = await readRowsFromFile(_selectedFile!);
      if (rows.isEmpty) {
        _addLog('No rows found in the selected file.');
        return;
      }

      final header = rows.first.map((e) => e?.toString().trim() ?? '').toList();
      final photoIndex = _findColumnIndex(header, photoColumnName);
      final nameIndex = _findColumnIndex(header, nameColumnName);
      final emailIndex = _findColumnIndex(header, emailColumnName);

      if (photoIndex == -1) {
        _addLog('Column "$photoColumnName" was not found in the header row.');
        return;
      }

      if (nameIndex == -1 || emailIndex == -1) {
        _addLog('Columns "$nameColumnName" and/or "$emailColumnName" were not found.');
        return;
      }

      final dataRows = rows.skip(1).toList();
      final tasks = <_DownloadTask>[];

      for (var i = 0; i < dataRows.length; i++) {
        final row = dataRows[i];
        if (row.length <= photoIndex) continue;

        final rawUrl = row[photoIndex]?.toString().trim() ?? '';
        if (rawUrl.isEmpty) continue;

        final name = _safeCell(row, nameIndex);
        final email = _safeCell(row, emailIndex);

        tasks.add(_DownloadTask(url: rawUrl, name: name, email: email));
      }

      if (tasks.isEmpty) {
        _addLog('No download links found in "$photoColumnName" column.');
        return;
      }

      setState(() {
        _totalCount = tasks.length;
      });

      if (kIsWeb && _zipOnWeb) {
        await _downloadAsZip(tasks);
      } else {
        for (var i = 0; i < tasks.length; i++) {
          final task = tasks[i];
          setState(() {
            _currentIndex = i + 1;
            _currentFileProgress = 0;
            _currentFileName = '';
          });

          await _downloadOne(task, _folderPath);
        }
      }

      _addLog('All downloads finished.');
      completedSuccessfully = true;
      setState(() {
        _currentIndex = _totalCount;
        _completedCount = _totalCount;
        _currentFileProgress = 1;
      });
    } catch (e) {
      _addLog('Error: $e');
    } finally {
      setState(() {
        _isRunning = false;
        if (!completedSuccessfully) {
          _currentFileProgress = 0;
        }
      });
    }
  }

  Future<void> _downloadAsZip(List<_DownloadTask> tasks) async {
    final archive = Archive();

    for (var i = 0; i < tasks.length; i++) {
      final task = tasks[i];
      setState(() {
        _currentIndex = i + 1;
        _currentFileProgress = 0;
        _currentFileName = '';
      });

      final uri = Uri.tryParse(task.url);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        _addLog('Skipping invalid URL: ${task.url}');
        continue;
      }

      final originalName = _filenameFromUrl(uri, fallbackIndex: _currentIndex);
      final filename = _buildOutputName(task.name, task.email, originalName);

      setState(() {
        _currentFileName = filename;
      });

      try {
        final bytes = await fetchBytes(
          dio: _dio,
          url: task.url,
          onProgress: (received, total) {
            if (total <= 0) return;
            setState(() {
              _currentFileProgress = received / total;
            });
          },
        );
        archive.addFile(ArchiveFile(filename, bytes.length, bytes));
        setState(() {
          _completedCount += 1;
        });
        _addLog('Queued: $filename');
      } catch (e) {
        _addLog('Failed: ${task.url}');
      }
    }

    _addLog('Creating ZIP...');
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null || zipBytes.isEmpty) {
      _addLog('ZIP creation failed.');
      return;
    }

    final now = DateTime.now();
    final zipName =
        'downloads_${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}.zip';

    await saveBytes(fileName: zipName, bytes: zipBytes);
    _addLog('ZIP downloaded: $zipName');
  }

  Future<void> _downloadOne(_DownloadTask task, String? folderPath) async {
    final uri = Uri.tryParse(task.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _addLog('Skipping invalid URL: ${task.url}');
      return;
    }

    final originalName = _filenameFromUrl(uri, fallbackIndex: _currentIndex);
    final filename = _buildOutputName(task.name, task.email, originalName);

    setState(() {
      _currentFileName = filename;
    });

    try {
      await downloadFile(
        dio: _dio,
        url: task.url,
        fileName: filename,
        folderPath: folderPath,
        onProgress: (received, total) {
          if (total <= 0) return;
          setState(() {
            _currentFileProgress = received / total;
          });
        },
      );
      setState(() {
        _completedCount += 1;
      });
      _addLog('Downloaded: $filename');
    } catch (e) {
      _addLog('Failed: ${task.url}');
    }
  }

  String _filenameFromUrl(Uri uri, {required int fallbackIndex}) {
    final pathSegments = uri.pathSegments;
    if (pathSegments.isEmpty) {
      return 'file_$fallbackIndex';
    }
    final last = pathSegments.last;
    if (last.isEmpty || last == '/') {
      return 'file_$fallbackIndex';
    }
    return last;
  }

  String _buildOutputName(String name, String email, String originalName) {
    final safeName = _sanitizeForFilename(name);
    final safeEmail = _sanitizeForFilename(email);
    final safeOriginal = _sanitizeForFilename(originalName);
    final parts = [safeName, safeEmail, safeOriginal].where((p) => p.isNotEmpty).toList();
    return parts.join('_');
  }

  String _sanitizeForFilename(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return '';
    final sanitized = trimmed.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    return sanitized.replaceAll(RegExp(r'\s+'), ' ');
  }

  String _safeCell(List<dynamic> row, int index) {
    if (index < 0 || index >= row.length) return '';
    return row[index]?.toString().trim() ?? '';
  }

  int _findColumnIndex(List<String> header, String columnName) {
    final target = columnName.toLowerCase();
    for (var i = 0; i < header.length; i++) {
      if (header[i].toLowerCase() == target) return i;
    }
    return -1;
  }

  double get _overallProgress {
    if (_totalCount == 0) return 0;
    if (!_isRunning && _completedCount >= _totalCount) {
      return 1;
    }
    final completed = _completedCount.clamp(0, _totalCount);
    final currentFraction = _currentFileProgress;
    return (completed + currentFraction).clamp(0, _totalCount) / _totalCount;
  }

  @override
  Widget build(BuildContext context) {
    final fileLabel = _selectedFile == null ? 'No file selected' : _selectedFile!.name;
    final folderLabel = kIsWeb ? 'Browser downloads folder' : (_folderPath ?? 'No folder selected');

    return Scaffold(
      appBar: AppBar(title: const Text('PMFTC Link Downloader')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              elevation: 0,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('1) Select file (.xlsx, .xls, .csv)'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: Text(fileLabel)),
                        const SizedBox(width: 12),
                        ElevatedButton(onPressed: _isRunning ? null : _pickFile, child: const Text('Choose File')),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text('2) Select download folder'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: Text(folderLabel, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 12),
                        ElevatedButton(onPressed: kIsWeb || _isRunning ? null : _pickFolder, child: const Text('Choose Folder')),
                      ],
                    ),
                    if (kIsWeb)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 6),
                          const Text('Web browsers always save to the default Downloads folder.', style: TextStyle(fontSize: 12)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Checkbox(
                                value: _zipOnWeb,
                                onChanged: _isRunning
                                    ? null
                                    : (value) {
                                        setState(() {
                                          _zipOnWeb = value ?? false;
                                        });
                                      },
                              ),
                              const Text('Download all as ZIP (web only)'),
                            ],
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    FilledButton.icon(onPressed: _isRunning ? null : _startDownload, icon: const Icon(Icons.download), label: const Text('Start Download')),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Overall progress: ${(_overallProgress * 100).toStringAsFixed(1)}%'),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: _overallProgress),
            const SizedBox(height: 12),
            Text('Current file: $_currentFileName'),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: _isRunning ? _currentFileProgress : 0),
            const SizedBox(height: 8),
            Text('File $_currentIndex / $_totalCount'),
            const SizedBox(height: 16),
            const Text('Logs'),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (context, index) {
                    return Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Text(_logs[index]));
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadTask {
  _DownloadTask({required this.url, required this.name, required this.email});

  final String url;
  final String name;
  final String email;
}
