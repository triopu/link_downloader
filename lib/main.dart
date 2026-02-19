import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'platform/default_folder.dart';
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
  static const int storeNameColumnIndex = 0;
  static const int imageUrlColumnIndex = 3;
  static const int createdOnColumnIndex = 9;
  static const String folderSuffix = 'ZYNsampling';

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

  @override
  void initState() {
    super.initState();
    _initializeDefaultFolder();
  }

  Future<void> _initializeDefaultFolder() async {
    if (kIsWeb) return;

    final folder = await getDefaultDownloadFolder();
    if (!mounted || folder == null || folder.isEmpty) return;

    setState(() {
      _folderPath = folder;
    });
  }

  void _addLog(String message) {
    setState(() {
      _logs.insert(0, message);
    });
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'xls', 'csv'],
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) return;

    setState(() {
      _selectedFile = result.files.single;
    });
  }

  Future<void> _startDownload() async {
    if (_selectedFile == null) {
      _addLog('Please select a file first.');
      return;
    }

    if (!kIsWeb && (_folderPath == null || _folderPath!.isEmpty)) {
      final autoFolder = await getDefaultDownloadFolder();
      if (autoFolder != null && autoFolder.isNotEmpty) {
        setState(() {
          _folderPath = autoFolder;
        });
      }
    }

    if (!kIsWeb && (_folderPath == null || _folderPath!.isEmpty)) {
      _addLog('Could not determine the default Downloads folder on this device.');
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

      final runDate = _formatYyyyMmDd(DateTime.now());
      final runFolderName = '${runDate}_$folderSuffix';
      String? outputFolderPath = _folderPath;
      if (!kIsWeb) {
        outputFolderPath = await prepareOutputFolder(
          baseFolderPath: _folderPath!,
          folderName: runFolderName,
        );
        _addLog('Saving downloads to: $outputFolderPath');
      }

      final dataRows = rows.skip(1).toList();
      final tasks = <_DownloadTask>[];
      final imageCounters = <String, int>{};

      for (var i = 0; i < dataRows.length; i++) {
        final row = dataRows[i];
        if (row.length <= imageUrlColumnIndex) continue;

        final rawUrl = row[imageUrlColumnIndex]?.toString().trim() ?? '';
        if (rawUrl.isEmpty) continue;

        final storeName = _safeCell(row, storeNameColumnIndex);
        final createdOn = _parseCreatedOn(row, createdOnColumnIndex);
        if (createdOn == null) {
          _addLog('Skipping row ${i + 2}: invalid "Created on" value in column J.');
          continue;
        }

        final createdDate = _formatYyyyMmDd(createdOn);
        final storeKey = storeName.toLowerCase();
        final counterKey = '$createdDate|$storeKey';
        final imageCount = (imageCounters[counterKey] ?? 0) + 1;
        imageCounters[counterKey] = imageCount;

        tasks.add(
          _DownloadTask(
            url: rawUrl,
            fileName: _buildImageName(
              createdDate: createdDate,
              storeName: storeName,
              imageCount: imageCount,
            ),
          ),
        );
      }

      if (tasks.isEmpty) {
        _addLog('No valid download links found in column D.');
        return;
      }

      setState(() {
        _totalCount = tasks.length;
      });

      if (kIsWeb && _zipOnWeb) {
        await _downloadAsZip(tasks, runFolderName: runFolderName);
      } else {
        for (var i = 0; i < tasks.length; i++) {
          final task = tasks[i];
          setState(() {
            _currentIndex = i + 1;
            _currentFileProgress = 0;
            _currentFileName = '';
          });

          await _downloadOne(task, outputFolderPath);
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

  Future<void> _downloadAsZip(List<_DownloadTask> tasks, {required String runFolderName}) async {
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

      final filename = task.fileName;
      final zipEntryPath = '$runFolderName/$filename';

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
        archive.addFile(ArchiveFile(zipEntryPath, bytes.length, bytes));
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

    final zipName = '$runFolderName.zip';

    await saveBytes(fileName: zipName, bytes: zipBytes);
    _addLog('ZIP downloaded: $zipName');
  }

  Future<void> _downloadOne(_DownloadTask task, String? folderPath) async {
    final uri = Uri.tryParse(task.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _addLog('Skipping invalid URL: ${task.url}');
      return;
    }

    final filename = task.fileName;

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

  String _buildImageName({
    required String createdDate,
    required String storeName,
    required int imageCount,
  }) {
    final safeStoreName = _sanitizeForFilename(storeName);
    final storeSegment = safeStoreName.isEmpty ? 'Store' : safeStoreName;
    return '${createdDate}_${storeSegment}_$imageCount.jpeg';
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

  DateTime? _parseCreatedOn(List<dynamic> row, int index) {
    if (index < 0 || index >= row.length) return null;
    final value = row[index];
    if (value == null) return null;

    if (value is DateTime) {
      return DateTime(value.year, value.month, value.day);
    }

    if (value is num) {
      final days = value.floor();
      final adjustedDays = days >= 60 ? days - 1 : days;
      final date = DateTime.utc(1899, 12, 31).add(Duration(days: adjustedDays));
      return DateTime(date.year, date.month, date.day);
    }

    final text = value.toString().trim();
    if (text.isEmpty) return null;

    final parsed = DateTime.tryParse(text);
    if (parsed != null) {
      final normalized = parsed.add(const Duration(hours: 12));
      return DateTime(normalized.year, normalized.month, normalized.day);
    }

    final ymd = RegExp(r'^(\d{4})[/-](\d{1,2})[/-](\d{1,2})').firstMatch(text);
    if (ymd != null) {
      final year = int.tryParse(ymd.group(1)!);
      final month = int.tryParse(ymd.group(2)!);
      final day = int.tryParse(ymd.group(3)!);
      if (year != null && month != null && day != null) {
        return DateTime(year, month, day);
      }
    }

    final dmy = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})').firstMatch(text);
    if (dmy != null) {
      final day = int.tryParse(dmy.group(1)!);
      final month = int.tryParse(dmy.group(2)!);
      var year = int.tryParse(dmy.group(3)!);
      if (year != null && year < 100) {
        year += 2000;
      }
      if (year != null && month != null && day != null) {
        return DateTime(year, month, day);
      }
    }

    return null;
  }

  String _formatYyyyMmDd(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year$month$day';
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
    final folderLabel = kIsWeb ? 'Browser downloads folder' : (_folderPath ?? 'Detecting default Downloads folder...');

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
                    const Text('2) Download folder'),
                    const SizedBox(height: 8),
                    Text(folderLabel, overflow: TextOverflow.ellipsis),
                    if (!kIsWeb)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'The app always uses your system Downloads folder automatically.',
                          style: TextStyle(fontSize: 12),
                        ),
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
  _DownloadTask({required this.url, required this.fileName});

  final String url;
  final String fileName;
}
