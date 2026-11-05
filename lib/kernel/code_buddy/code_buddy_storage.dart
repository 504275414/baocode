import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';
import '../agent_kernel.dart';

/// Reads and manages CodeBuddy sessions stored on this machine in an isolated
/// BaoCode directory (defaulting to `DataDirectory.current.path/codebuddy`).
class CodeBuddyStorage implements SessionCatalog {
  const CodeBuddyStorage({this.configDir});

  /// The root directory for BaoCode's CodeBuddy state.
  final String? configDir;

  /// Default isolated configuration directory for CodeBuddy under BaoCode.
  static String get defaultConfigDir {
    final custom = Platform.environment['BAOCODE_CODEBUDDY_DATA_PATH'];
    if (custom != null && custom.isNotEmpty) return custom;
    return p.join(DataDirectory.current.path, 'codebuddy');
  }

  /// Ensures the isolated configuration directory exists and syncs authentication
  /// and model settings from the user's global `~/.codebuddy` directory.
  static void ensureIsolatedConfigDir([String? targetDir]) {
    final dir = targetDir ?? defaultConfigDir;
    final target = Directory(dir);
    if (!target.existsSync()) {
      try {
        target.createSync(recursive: true);
      } catch (_) {
        return;
      }
    }

    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    if (home.isEmpty) return;
    final globalCodebuddy = p.join(home, '.codebuddy');
    if (!Directory(globalCodebuddy).existsSync()) return;

    // 1. Sync local_storage (stores authentication tokens)
    final globalLocalStorage = Directory(p.join(globalCodebuddy, 'local_storage'));
    final targetLocalStorage = Directory(p.join(dir, 'local_storage'));
    if (globalLocalStorage.existsSync()) {
      _copyDirectoryIfNewer(globalLocalStorage, targetLocalStorage);
    }

    // 2. Sync settings.json, models.json, mcp.json
    for (final fileName in ['settings.json', 'models.json', 'mcp.json']) {
      final globalFile = File(p.join(globalCodebuddy, fileName));
      final targetFile = File(p.join(dir, fileName));
      if (globalFile.existsSync()) {
        if (!targetFile.existsSync() ||
            globalFile.lastModifiedSync().isAfter(targetFile.lastModifiedSync())) {
          try {
            globalFile.copySync(targetFile.path);
          } catch (_) {}
        }
      }
    }
  }

  static void _copyDirectoryIfNewer(Directory src, Directory dst) {
    if (!src.existsSync()) return;
    if (!dst.existsSync()) {
      try {
        dst.createSync(recursive: true);
      } catch (_) {
        return;
      }
    }
    for (final entity in src.listSync(recursive: false)) {
      if (entity is File) {
        final targetFile = File(p.join(dst.path, p.basename(entity.path)));
        if (!targetFile.existsSync() ||
            entity.lastModifiedSync().isAfter(targetFile.lastModifiedSync())) {
          try {
            entity.copySync(targetFile.path);
          } catch (_) {}
        }
      } else if (entity is Directory) {
        _copyDirectoryIfNewer(
          entity,
          Directory(p.join(dst.path, p.basename(entity.path))),
        );
      }
    }
  }

  String get _root {
    if (configDir case final dir? when dir.isNotEmpty) return dir;
    return defaultConfigDir;
  }

  String get _projectsDir => p.join(_root, 'projects');

  @override
  Future<List<ProjectRecord>> projects() async {
    ensureIsolatedConfigDir(_root);
    final rootDir = Directory(_projectsDir);
    if (!rootDir.existsSync()) return const [];

    final projectMap = <String, List<SessionRecord>>{};

    for (final entity in rootDir.listSync().whereType<Directory>()) {
      final jsonlFiles = entity
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jsonl'))
          .toList();

      String? fallbackCwd;
      for (final file in jsonlFiles) {
        fallbackCwd = _quickDetectCwd(file);
        if (fallbackCwd != null) break;
      }

      for (final file in jsonlFiles) {
        final record = _parseSessionFile(file, fallbackCwd: fallbackCwd);
        if (record == null) continue;
        (projectMap[record.cwd] ??= []).add(record);
      }
    }

    final result = <ProjectRecord>[];
    for (final MapEntry(key: cwd, value: sessions) in projectMap.entries) {
      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      result.add(ProjectRecord(path: cwd, sessions: sessions));
    }

    result.sort((a, b) {
      final aTime = a.updatedAt;
      final bTime = b.updatedAt;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });

    return result;
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final allProjects = await projects();
    final normalized = p.normalize(cwd);
    for (final project in allProjects) {
      if (p.equals(p.normalize(project.path), normalized)) {
        return project.sessions;
      }
    }
    return const [];
  }

  @override
  Future<void> delete(String id) async {
    final rootDir = Directory(_projectsDir);
    if (!rootDir.existsSync()) return;

    for (final entity in rootDir.listSync().whereType<Directory>()) {
      final sessionFile = File(p.join(entity.path, '$id.jsonl'));
      if (sessionFile.existsSync()) {
        try {
          sessionFile.deleteSync();
        } on FileSystemException {
          // Ignore
        }
      }
      final sessionDir = Directory(p.join(entity.path, id));
      if (sessionDir.existsSync()) {
        try {
          sessionDir.deleteSync(recursive: true);
        } on FileSystemException {
          // Ignore
        }
      }
    }
  }

  /// Copies a session file up to [before] into a new session [into].
  Future<SessionRecord?> fork(
    String id,
    String into, {
    String? before,
    String? title,
  }) async {
    final rootDir = Directory(_projectsDir);
    if (!rootDir.existsSync()) return null;

    File? sourceFile;
    for (final entity in rootDir.listSync().whereType<Directory>()) {
      final file = File(p.join(entity.path, '$id.jsonl'));
      if (file.existsSync()) {
        sourceFile = file;
        break;
      }
    }
    if (sourceFile == null) return null;

    final lines = sourceFile.readAsLinesSync();
    if (lines.isEmpty) return null;

    final out = <String>[];
    String? cwd;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final json = jsonDecode(trimmed) as Map<String, Object?>;
        if (json['cwd'] is String) cwd = json['cwd'] as String;
        if (before != null && (json['id'] == before || json['messageId'] == before)) {
          break;
        }
        json['sessionId'] = into;
        out.add(jsonEncode(json));
      } catch (_) {
        out.add(line);
      }
    }

    if (title != null && title.trim().isNotEmpty) {
      out.add(jsonEncode({
        'type': 'ai-title',
        'aiTitle': title.trim(),
        'sessionId': into,
      }));
    }

    final targetFile = File(p.join(sourceFile.parent.path, '$into.jsonl'));
    targetFile.writeAsStringSync('${out.join('\n')}\n', flush: true);

    return SessionRecord(
      id: into,
      title: title ?? 'Fork of $id',
      updatedAt: DateTime.now(),
      cwd: cwd ?? Directory.current.path,
      path: targetFile.path,
    );
  }

  static String? _quickDetectCwd(File file) {
    try {
      final lines = file.readAsLinesSync();
      for (final line in lines) {
        if (!line.contains('"cwd"')) continue;
        final json = jsonDecode(line);
        if (json is Map && json['cwd'] is String) {
          final cwd = json['cwd'] as String;
          if (cwd.isNotEmpty) return cwd;
        }
      }
    } catch (_) {}
    return null;
  }

  static SessionRecord? _parseSessionFile(File file, {String? fallbackCwd}) {
    try {
      final stat = file.statSync();
      if (stat.type == FileSystemEntityType.notFound) return null;

      final id = p.basenameWithoutExtension(file.path);
      String? cwd = fallbackCwd;
      String? aiTitle;
      String? summary;
      String? firstUserMessage;
      int? latestTimestamp;
      var hasActualMessages = false;

      final lines = file.readAsLinesSync();
      if (lines.isEmpty) return null;

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final json = jsonDecode(trimmed) as Map<String, Object?>;

          if (json['cwd'] is String && (json['cwd'] as String).isNotEmpty) {
            cwd = json['cwd'] as String;
          }

          if (json['timestamp'] case final int ts) {
            if (latestTimestamp == null || ts > latestTimestamp) {
              latestTimestamp = ts;
            }
          }

          final type = json['type'] as String?;
          if (type == 'ai-title' && json['aiTitle'] is String) {
            aiTitle = json['aiTitle'] as String;
          } else if (type == 'summary' && json['summary'] is String) {
            summary = json['summary'] as String;
          } else if (type == 'message') {
            hasActualMessages = true;
            if (json['role'] == 'user') {
              if (firstUserMessage == null && json['content'] is List) {
                for (final item in json['content'] as List) {
                  if (item is Map &&
                      item['type'] == 'input_text' &&
                      item['text'] is String) {
                    firstUserMessage = item['text'] as String;
                    break;
                  }
                }
              }
            }
          }
        } on FormatException {
          continue;
        }
      }

      if (!hasActualMessages && summary == null && aiTitle == null) {
        return null;
      }

      if (cwd == null || cwd.isEmpty) {
        return null;
      }

      final title = (aiTitle != null && aiTitle.isNotEmpty)
          ? aiTitle
          : (summary != null && summary.isNotEmpty)
              ? summary
              : (firstUserMessage != null && firstUserMessage.isNotEmpty)
                  ? firstUserMessage
                  : id;

      final updatedAt = latestTimestamp != null
          ? DateTime.fromMillisecondsSinceEpoch(latestTimestamp)
          : stat.modified;

      return SessionRecord(
        id: id,
        title: title,
        updatedAt: updatedAt,
        cwd: cwd,
        path: file.path,
      );
    } catch (_) {
      return null;
    }
  }
}
