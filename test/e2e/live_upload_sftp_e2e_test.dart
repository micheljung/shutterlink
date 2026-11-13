@Tags(['sftp'])
library;

import 'package:flutter_test/flutter_test.dart';

import 'live_upload_pipeline.dart';

void main() => pipelineTests(SftpRemote.start);
