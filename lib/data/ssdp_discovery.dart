import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:equatable/equatable.dart';

const ssdpDiscoveryTimeout = Duration(seconds: 3);
const ssdpDescriptionTimeout = Duration(seconds: 2);
const ssdpSearchRepeats = 3;
const ssdpMulticastGroup = '239.255.255.250';
const ssdpPort = 1900;
const canonSearchTargets = [
  'urn:schemas-canon-com:service:ICPO-SmartPhoneEOSSystemService:1',
  'urn:schemas-canon-com:service:ICPO-WFTEOSSystemService:1',
];

class DiscoveredCamera extends Equatable {
  const DiscoveredCamera({required this.host, required this.name});

  final String host;
  final String name;

  @override
  List<Object?> get props => [host, name];
}

class SsdpDiscovery {
  const SsdpDiscovery({
    this.group = ssdpMulticastGroup,
    this.searchPort = ssdpPort,
    this.listenPort = ssdpPort,
    this.searchTargets = canonSearchTargets,
    this.descriptionTimeout = ssdpDescriptionTimeout,
  });

  static const _searchMaxWaitSeconds = 1;
  static const _okStatus = 200;
  static final _friendlyName = RegExp(
    '<friendlyName>([^<]*)</friendlyName>',
    caseSensitive: false,
  );

  final String group;
  final int searchPort;
  final int listenPort;
  final List<String> searchTargets;
  final Duration descriptionTimeout;

  Future<List<DiscoveredCamera>> discover({
    Duration timeout = ssdpDiscoveryTimeout,
  }) async {
    final groupAddress = InternetAddress(group);
    final cameras = <String, Future<DiscoveredCamera>>{};
    void onDatagram(RawDatagramSocket socket) {
      final datagram = socket.receive();
      if (datagram == null) return;
      final location = _cameraLocation(datagram.data);
      if (location == null) return;
      cameras.putIfAbsent(location.host, () => _describe(location));
    }

    final searcher = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final listener = await _bindListener(groupAddress);
    final sockets = [searcher, ?listener];
    try {
      for (final socket in sockets) {
        socket.listen((event) {
          if (event == RawSocketEvent.read) onDatagram(socket);
        });
      }
      final interval = timeout ~/ ssdpSearchRepeats;
      for (var repeat = 0; repeat < ssdpSearchRepeats; repeat++) {
        for (final target in searchTargets) {
          searcher.send(_search(target), groupAddress, searchPort);
        }
        await Future<void>.delayed(interval);
      }
    } finally {
      for (final socket in sockets) {
        socket.close();
      }
    }
    return Future.wait(cameras.values);
  }

  Future<RawDatagramSocket?> _bindListener(InternetAddress groupAddress) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        listenPort,
        reuseAddress: true,
      );
      if (groupAddress.isMulticast) socket.joinMulticast(groupAddress);
      return socket;
    } on SocketException {
      socket?.close();
      return null;
    }
  }

  List<int> _search(String target) => utf8.encode(
    'M-SEARCH * HTTP/1.1\r\n'
    'HOST: $group:$searchPort\r\n'
    'MAN: "ssdp:discover"\r\n'
    'MX: $_searchMaxWaitSeconds\r\n'
    'ST: $target\r\n'
    '\r\n',
  );

  Uri? _cameraLocation(List<int> data) {
    final lines = const LineSplitter().convert(
      utf8.decode(data, allowMalformed: true),
    );
    if (lines.isEmpty) return null;
    final startLine = lines.first.trim().split(' ');
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      headers[line.substring(0, colon).trim().toUpperCase()] = line
          .substring(colon + 1)
          .trim();
    }
    final String? target;
    if (startLine.first == 'NOTIFY') {
      if (headers['NTS'] != 'ssdp:alive') return null;
      target = headers['NT'];
    } else if (startLine.first.startsWith('HTTP/') &&
        startLine.length > 1 &&
        int.tryParse(startLine[1]) == _okStatus) {
      target = headers['ST'];
    } else {
      return null;
    }
    if (!searchTargets.contains(target)) return null;
    final location = Uri.tryParse(headers['LOCATION'] ?? '');
    if (location == null ||
        !location.isScheme('http') ||
        location.host.isEmpty) {
      return null;
    }
    return location;
  }

  Future<DiscoveredCamera> _describe(Uri location) async {
    final client = HttpClient()..connectionTimeout = descriptionTimeout;
    try {
      final request = await client.getUrl(location).timeout(descriptionTimeout);
      final response = await request.close().timeout(descriptionTimeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(descriptionTimeout);
      final name = _friendlyName.firstMatch(body)?.group(1)?.trim();
      return DiscoveredCamera(
        host: location.host,
        name: name == null || name.isEmpty ? location.host : name,
      );
    } on Exception {
      return DiscoveredCamera(host: location.host, name: location.host);
    } finally {
      client.close(force: true);
    }
  }
}
