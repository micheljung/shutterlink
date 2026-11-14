/// The camera sent bytes that break the PTP framing or a dataset layout.
class PtpProtocolException implements Exception {
  const PtpProtocolException(this.message);

  final String message;

  @override
  String toString() => 'PtpProtocolException: $message';
}
