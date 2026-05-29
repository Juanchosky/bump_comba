import 'dart:convert';
import 'dart:typed_data';
import '../models/m3u_item.dart';

/// Helper to write binary data into a growable byte stream.
class BipbWriter {
  final BytesBuilder builder = BytesBuilder(copy: false);

  void writeUint8(int val) {
    builder.addByte(val);
  }

  void writeUint16(int val) {
    final data = ByteData(2);
    data.setUint16(0, val, Endian.little);
    builder.add(data.buffer.asUint8List());
  }

  void writeUint32(int val) {
    final data = ByteData(4);
    data.setUint32(0, val, Endian.little);
    builder.add(data.buffer.asUint8List());
  }

  void writeInt32(int val) {
    final data = ByteData(4);
    data.setInt32(0, val, Endian.little);
    builder.add(data.buffer.asUint8List());
  }

  void writeBytes(Uint8List bytes) {
    builder.add(bytes);
  }

  Uint8List toBytes() => builder.takeBytes();
}

/// Helper to read binary data from a byte buffer.
class BipbReader {
  final Uint8List bytes;
  int _offset = 0;
  late ByteData _byteData;

  BipbReader(this.bytes) {
    _byteData = ByteData.sublistView(bytes);
  }

  int get offset => _offset;
  bool get hasMore => _offset < bytes.length;

  int readUint8() {
    final val = _byteData.getUint8(_offset);
    _offset += 1;
    return val;
  }

  int readUint16() {
    final val = _byteData.getUint16(_offset, Endian.little);
    _offset += 2;
    return val;
  }

  int readUint32() {
    final val = _byteData.getUint32(_offset, Endian.little);
    _offset += 4;
    return val;
  }

  int readInt32() {
    final val = _byteData.getInt32(_offset, Endian.little);
    _offset += 4;
    return val;
  }

  Uint8List readBytes(int length) {
    final val = bytes.sublist(_offset, _offset + length);
    _offset += length;
    return val;
  }
}

/// Serializer for BIPB (Bump IPTV Binary) format.
///
/// Features a self-contained string pool to heavily de-duplicate repeating tags/categories/URLs,
/// resulting in extremely small binary payloads and near-zero memory footprint.
class BipbSerializer {
  static const int magic = 0x42495042; // 'BIPB'
  static const int version = 1;

  /// Serializes a list of M3UItem objects into a binary buffer.
  static Uint8List serialize(List<M3UItem> items) {
    final List<String> stringPool = [];
    final Map<String, int> stringToIndex = {};

    void addString(String? s) {
      if (s == null) return;
      if (!stringToIndex.containsKey(s)) {
        stringToIndex[s] = stringPool.length;
        stringPool.add(s);
      }
    }

    void collectStrings(M3UItem item) {
      addString(item.name);
      addString(item.url);
      addString(item.logo);
      addString(item.category);
      addString(item.duration);
      addString(item.seriesName);
      addString(item.sourceName);
      for (final ep in item.episodes) {
        collectStrings(ep);
      }
      for (final alt in item.alternatives) {
        collectStrings(alt);
      }
    }

    for (final item in items) {
      collectStrings(item);
    }

    final writer = BipbWriter();

    // 1. Write Header
    writer.writeUint32(magic);
    writer.writeUint32(version);

    // 2. Write String Pool
    writer.writeUint32(stringPool.length);
    for (final s in stringPool) {
      final bytes = utf8.encode(s);
      if (bytes.length > 65535) {
        final truncated = bytes.sublist(0, 65535);
        writer.writeUint16(truncated.length);
        writer.writeBytes(Uint8List.fromList(truncated));
      } else {
        writer.writeUint16(bytes.length);
        writer.writeBytes(Uint8List.fromList(bytes));
      }
    }

    int getStrIndex(String? s) {
      if (s == null) return 0xFFFFFFFF;
      return stringToIndex[s] ?? 0xFFFFFFFF;
    }

    // 3. Write Data recursively
    void writeItem(M3UItem item) {
      writer.writeUint32(getStrIndex(item.name));
      writer.writeUint32(getStrIndex(item.url));
      writer.writeUint32(getStrIndex(item.logo));
      writer.writeUint32(getStrIndex(item.category));
      writer.writeUint32(getStrIndex(item.duration));
      writer.writeUint32(getStrIndex(item.seriesName));
      writer.writeUint32(getStrIndex(item.sourceName));

      writer.writeInt32(item.seasonNumber ?? -1);
      writer.writeInt32(item.episodeNumber ?? -1);

      int flags = 0;
      if (item.isFavorite) flags |= (1 << 0);
      if (item.isLive) flags |= (1 << 1);
      if (item.isDynamic) flags |= (1 << 2);

      final explicit = item.explicitIsSeries;
      if (explicit == true) {
        flags |= (1 << 3); // isSeries is true
        flags |= (1 << 6); // hasExplicitIsSeries
      } else if (explicit == false) {
        flags |= (1 << 6); // hasExplicitIsSeries (isSeries bit is 0)
      }

      if (item.episodes.isNotEmpty) flags |= (1 << 4);
      if (item.alternatives.isNotEmpty) flags |= (1 << 5);

      writer.writeUint8(flags);

      if (item.episodes.isNotEmpty) {
        writer.writeUint32(item.episodes.length);
        for (final ep in item.episodes) {
          writeItem(ep);
        }
      }

      if (item.alternatives.isNotEmpty) {
        writer.writeUint32(item.alternatives.length);
        for (final alt in item.alternatives) {
          writeItem(alt);
        }
      }
    }

    writer.writeUint32(items.length);
    for (final item in items) {
      writeItem(item);
    }

    return writer.toBytes();
  }

  /// Deserializes a BIPB binary buffer into a list of M3UItem objects.
  static List<M3UItem> deserialize(Uint8List bytes) {
    if (bytes.length < 8) {
      throw Exception('Invalid BIPB file size');
    }

    final reader = BipbReader(bytes);
    final fileMagic = reader.readUint32();
    if (fileMagic != magic) {
      throw Exception('Invalid BIPB magic header');
    }
    final fileVersion = reader.readUint32();
    if (fileVersion != 1) {
      throw Exception('Unsupported BIPB version $fileVersion');
    }

    // Read String Pool
    final numStrings = reader.readUint32();
    final List<String> stringPool = List<String>.filled(numStrings, '');
    for (int i = 0; i < numStrings; i++) {
      final len = reader.readUint16();
      final strBytes = reader.readBytes(len);
      stringPool[i] = utf8.decode(strBytes, allowMalformed: true);
    }

    String? getStr(int index) {
      if (index == 0xFFFFFFFF) return null;
      return stringPool[index];
    }

    M3UItem readItem() {
      final name = getStr(reader.readUint32()) ?? '';
      final url = getStr(reader.readUint32()) ?? '';
      final logo = getStr(reader.readUint32());
      final category = getStr(reader.readUint32()) ?? 'Sin categoría';
      final duration = getStr(reader.readUint32());
      final seriesName = getStr(reader.readUint32());
      final sourceName = getStr(reader.readUint32());

      final seasonNumber = reader.readInt32();
      final episodeNumber = reader.readInt32();

      final flags = reader.readUint8();
      final isFavorite = (flags & (1 << 0)) != 0;
      final isLive = (flags & (1 << 1)) != 0;
      final isDynamic = (flags & (1 << 2)) != 0;

      bool? isSeries;
      if ((flags & (1 << 6)) != 0) {
        isSeries = (flags & (1 << 3)) != 0;
      }

      final hasEpisodes = (flags & (1 << 4)) != 0;
      final hasAlternatives = (flags & (1 << 5)) != 0;

      List<M3UItem> episodes = const [];
      if (hasEpisodes) {
        final count = reader.readUint32();
        final list = <M3UItem>[];
        for (int i = 0; i < count; i++) {
          list.add(readItem());
        }
        episodes = list;
      }

      List<M3UItem> alternatives = const [];
      if (hasAlternatives) {
        final count = reader.readUint32();
        final list = <M3UItem>[];
        for (int i = 0; i < count; i++) {
          list.add(readItem());
        }
        alternatives = list;
      }

      return M3UItem(
        name: name,
        url: url,
        logo: logo,
        category: category,
        isFavorite: isFavorite,
        episodes: episodes,
        seriesName: seriesName,
        seasonNumber: seasonNumber == -1 ? null : seasonNumber,
        episodeNumber: episodeNumber == -1 ? null : episodeNumber,
        isSeries: isSeries,
        isLive: isLive,
        isDynamic: isDynamic,
        alternatives: alternatives,
        sourceName: sourceName,
        duration: duration,
      );
    }

    final numItems = reader.readUint32();
    final List<M3UItem> items = [];
    for (int i = 0; i < numItems; i++) {
      items.add(readItem());
    }

    return items;
  }
}
