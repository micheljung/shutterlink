import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import 'canon_eos.dart';
import 'connection.dart';

const canonEventHeaderSize = 8;
const _u32Size = 4;
const _typeOffset = _u32Size;
const _handleOffset = 0x08;
const _storageOffset = 0x0C;
const _formatOffset = 0x10;
const _sizeOffset = 0x1C;
const _parentOffset = 0x20;
const _nameOffset = 0x28;
const _parentOffset64 = 0x24;
const _nameOffset64 = 0x2C;
const _transferMinSize = _handleOffset + _u32Size;

sealed class CanonEvent extends Equatable {
  const CanonEvent();
}

class CanonObjectAdded extends CanonEvent {
  const CanonObjectAdded({
    required this.handle,
    required this.storageId,
    required this.format,
    required this.size,
    required this.parent,
  });

  final int handle;
  final int storageId;
  final int format;
  final int size;
  final int parent;

  @override
  List<Object?> get props => [handle, storageId, format, size, parent];
}

class CanonTransferRequested extends CanonEvent {
  const CanonTransferRequested(this.handle);

  final int handle;

  @override
  List<Object?> get props => [handle];
}

class CanonEventRecord {
  const CanonEventRecord(this.type, this.bytes);

  final int type;

  /// The whole record, header included.
  final Uint8List bytes;
}

/// Splits a Canon EOS GetEvent response into its records, following
/// libgphoto2's `ptp_unpack_CANON_changes`.
List<CanonEventRecord> canonEventRecords(Uint8List data) {
  final view = ByteData.sublistView(data);
  final records = <CanonEventRecord>[];
  var offset = 0;
  while (offset + canonEventHeaderSize <= data.length) {
    final size = view.getUint32(offset, Endian.little);
    final type = view.getUint32(offset + _typeOffset, Endian.little);
    if (type == CanonEosEvent.terminator && size == canonEventHeaderSize) {
      break;
    }
    if (size < canonEventHeaderSize || offset + size > data.length) {
      throw PtpIpProtocolException(
        'Malformed Canon event at $offset: size $size of ${data.length}',
      );
    }
    records.add(
      CanonEventRecord(
        type,
        Uint8List.sublistView(data, offset, offset + size),
      ),
    );
    offset += size;
  }
  return records;
}

List<CanonEvent> parseCanonEvents(Uint8List data) =>
    canonEventRecords(data).map(parseCanonEvent).nonNulls.toList();

/// Records of unknown type, or too short for their layout, yield null.
CanonEvent? parseCanonEvent(CanonEventRecord record) {
  final view = ByteData.sublistView(record.bytes);
  final length = record.bytes.length;
  int u32(int at) => view.getUint32(at, Endian.little);
  switch (record.type) {
    case CanonEosEvent.objectAddedEx when length >= _nameOffset:
      return CanonObjectAdded(
        handle: u32(_handleOffset),
        storageId: u32(_storageOffset),
        format: view.getUint16(_formatOffset, Endian.little),
        size: u32(_sizeOffset),
        parent: u32(_parentOffset),
      );
    case CanonEosEvent.objectAddedEx64 when length >= _nameOffset64:
      return CanonObjectAdded(
        handle: u32(_handleOffset),
        storageId: u32(_storageOffset),
        format: view.getUint16(_formatOffset, Endian.little),
        size: view.getUint64(_sizeOffset, Endian.little),
        parent: u32(_parentOffset64),
      );
    case CanonEosEvent.requestObjectTransfer ||
            CanonEosEvent.requestObjectTransfer64
        when length >= _transferMinSize:
      return CanonTransferRequested(u32(_handleOffset));
    default:
      return null;
  }
}
