import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class IosAppStoreUpdate {
  const IosAppStoreUpdate({required this.version, required this.storeUri});

  final String version;
  final Uri storeUri;
}

/// Checks Apple's public App Store catalog and fails closed on invalid data.
class IosAppStoreUpdateService {
  const IosAppStoreUpdateService({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  Future<IosAppStoreUpdate?> findUpdate({
    required String bundleId,
    required String installedVersion,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (bundleId.trim().isEmpty || installedVersion.trim().isEmpty) {
      return null;
    }
    final client = _clientFactory();
    try {
      final uri = Uri.https('itunes.apple.com', '/lookup', {
        'bundleId': bundleId.trim(),
      });
      final response = await client.get(uri).timeout(timeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['resultCount'] != 1) {
        return null;
      }
      final results = decoded['results'];
      if (results is! List ||
          results.length != 1 ||
          results.first is! Map<String, dynamic>) {
        return null;
      }
      final item = results.first as Map<String, dynamic>;
      final version = item['version'];
      final trackViewUrl = item['trackViewUrl'];
      if (version is! String ||
          !_isNewerVersion(version, installedVersion) ||
          trackViewUrl is! String) {
        return null;
      }
      final storeUri = Uri.tryParse(trackViewUrl);
      if (storeUri == null || !_isTrustedAppleStoreUri(storeUri)) return null;
      return IosAppStoreUpdate(version: version, storeUri: storeUri);
    } catch (error) {
      debugPrint('Apple lookup response unavailable: $error');
      return null;
    } finally {
      client.close();
    }
  }

  Future<bool> openStore(Uri storeUri) async {
    if (!_isTrustedAppleStoreUri(storeUri)) return false;
    try {
      return await launchUrl(
        storeUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      debugPrint('App Store launch failed: $error');
      return false;
    }
  }
}

bool _isTrustedAppleStoreUri(Uri uri) {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasPort) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return host == 'apps.apple.com' || host == 'itunes.apple.com';
}

bool _isNewerVersion(String candidate, String current) {
  List<int>? components(String value) {
    final core = value.trim().split(RegExp(r'[-+]')).first;
    final parts = core.split('.');
    if (parts.isEmpty || parts.any((part) => int.tryParse(part) == null)) {
      return null;
    }
    return parts.map(int.parse).toList();
  }

  final candidateParts = components(candidate);
  final currentParts = components(current);
  if (candidateParts == null || currentParts == null) return false;
  final length = candidateParts.length > currentParts.length
      ? candidateParts.length
      : currentParts.length;
  for (var index = 0; index < length; index++) {
    final next = index < candidateParts.length ? candidateParts[index] : 0;
    final installed = index < currentParts.length ? currentParts[index] : 0;
    if (next != installed) return next > installed;
  }
  return false;
}
