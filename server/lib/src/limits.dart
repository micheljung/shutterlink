const int _mebibyte = 1024 * 1024;
const int _gibibyte = 1024 * _mebibyte;

const int maxPhotoBytes = 50 * _mebibyte;
const int maxSessionBytes = 2 * _gibibyte;
const int maxSessionPhotos = 0xFFFF;

const Duration defaultRetention = Duration(days: 30);
const Duration tombstoneRetention = Duration(days: 60);

const int zipConcurrency = 2;
const Duration zipQueueTimeout = Duration(seconds: 30);

/// How long a zip download may go without the client taking more data.
const Duration zipIdleTimeout = Duration(seconds: 60);
