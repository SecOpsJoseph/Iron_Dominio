import 'package:flutter_test/flutter_test.dart';
import 'package:iron_dominio/updater_service.dart';

void main() {
  group('AppUpdateService', () {
    test('detecta versión nueva cuando el release es mayor', () {
      expect(
        AppUpdateService.isVersionNewer('v1.2.0', '1.1.9'),
        isTrue,
      );
    });

    test('no marca nueva versión si la actual es igual o mayor', () {
      expect(
        AppUpdateService.isVersionNewer('1.1.9', '1.2.0'),
        isFalse,
      );
      expect(
        AppUpdateService.isVersionNewer('1.2.0', '1.2.0'),
        isFalse,
      );
    });

    test('extrae la URL de descarga del primer APK disponible', () {
      final payload = {
        'tag_name': 'v1.2.0',
        'html_url': 'https://github.com/josep/iron_dominio/releases/tag/v1.2.0',
        'assets': [
          {'browser_download_url': 'https://example.com/other.zip'},
          {'browser_download_url': 'https://example.com/app-release.apk'},
        ],
      };

      expect(
        AppUpdateService.extractDownloadUrl(payload),
        'https://example.com/app-release.apk',
      );
    });
  });
}
