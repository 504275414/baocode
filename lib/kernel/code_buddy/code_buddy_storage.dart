import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../agent_kernel.dart';

/// Reads and manages CodeBuddy sessions stored on this machine (in `~/.codebuddy`).
class CodeBuddyStorage implements SessionCatalog {
  const CodeBuddyStorage({this.configDir});

  /// The root `.codebuddy` directory. By default `~/.codebuddy`.
  final String? configDir;

  String get _root {
    if (configDir case final dir? when dir.isNotEmpty) return dir;
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? Directory.current.path;
    return p.join(home, '.codebuddy');
  }

  String get _projectsDir => p.join(_root, 'projects');

  @override
  Future<List<ProjectRecord>> projects() async {
    final rootDir = Directory(_projectsDir);
    if (!rootDir.existsSync()) return const [];

    final projectMap = <String, List<SessionRecord>>{};

    for (final entity in rootDir.listSync().whereType<Directory>()) {
      final jsonlFiles = entity
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jsonl'))
          .toList();

      // First pass: try to detect the project's canonical cwd from any session file
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

      // Skip untouched/empty sessions with no actual user/assistant interaction
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
