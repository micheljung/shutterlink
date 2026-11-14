import 'package:flutter_test/flutter_test.dart';

import 'live_upload_pipeline.dart';

void main() {
  group('WebDAV', () => pipelineTests(WebDavRemote.start));
  group('S3', () => pipelineTests(S3Remote.start));
  group('Immich', () => pipelineTests(ImmichRemote.start, namedFiles: false));
}
