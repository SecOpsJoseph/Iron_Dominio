import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class GitHubRelease {
  const GitHubRelease({
    required this.tagName,
    required this.downloadUrl,
    required this.htmlUrl,
  });

  final String tagName;
  final String downloadUrl;
  final String htmlUrl;
}

class AppUpdateService {
  static const String _owner = 'josep';
  static const String _repo = 'iron_dominio';
  static const String _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  static bool isVersionNewer(String latestTag, String currentVersion) {
    final latest = _normalizeVersion(latestTag);
    final current = _normalizeVersion(currentVersion);
    if (latest == null || current == null) {
      return false;
    }

    for (var i = 0; i < 3; i++) {
      if (latest[i] > current[i]) return true;
      if (latest[i] < current[i]) return false;
    }

    return false;
  }

  static String? extractDownloadUrl(Map<String, dynamic> releaseData) {
    final assets = releaseData['assets'] as List<dynamic>? ?? const [];

    for (final asset in assets) {
      if (asset is Map<String, dynamic>) {
        final url = asset['browser_download_url'];
        if (url is String && url.trim().isNotEmpty) {
          return url;
        }
      }
      if (asset is Map) {
        final url = asset['browser_download_url'];
        if (url is String && url.trim().isNotEmpty) {
          return url;
        }
      }
    }

    final htmlUrl = releaseData['html_url'];
    if (htmlUrl is String && htmlUrl.trim().isNotEmpty) {
      return htmlUrl;
    }

    return null;
  }

  static Future<GitHubRelease?> checkForUpdate() async {
    try {
      final response = await http.get(
        Uri.parse(_apiUrl),
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'IronDominio-App',
        },
      );

      if (response.statusCode != 200) {
        return null;
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        return null;
      }

      final tagName = (data['tag_name'] ?? '') as String;
      final downloadUrl = extractDownloadUrl(data);

      if (tagName.trim().isEmpty || downloadUrl == null || downloadUrl.trim().isEmpty) {
        return null;
      }

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      if (!isVersionNewer(tagName, currentVersion)) {
        return null;
      }

      return GitHubRelease(
        tagName: tagName,
        downloadUrl: downloadUrl,
        htmlUrl: (data['html_url'] ?? '') as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  static List<int>? _normalizeVersion(String value) {
    final cleaned = value.trim();
    if (cleaned.isEmpty) {
      return null;
    }

    final withoutPrefix = cleaned.replaceFirst(RegExp(r'^[vV]'), '');
    final parts = withoutPrefix
        .split(RegExp(r'[^0-9]+'))
        .where((part) => part.isNotEmpty)
        .map(int.parse)
        .toList();

    if (parts.isEmpty) {
      return null;
    }

    while (parts.length < 3) {
      parts.add(0);
    }

    return parts.sublist(0, 3);
  }
}
