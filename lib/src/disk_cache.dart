import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'package:disk_lru_cache/disk_lru_cache.dart';
import 'package:http/http.dart';
import 'package:http_cache_client/src/cache_meta_data.dart';
import 'package:synchronized/synchronized.dart';

class DiskCache {
  final Directory directory;
  final int maxSize;

  File _metaDataFile;

  Map<String, CacheMetaData> _metaData;

  final _lock = Lock();

  DiskLruCache _lruCache;

  DiskCache({
    this.directory,
    this.maxSize = 20 * 1024 * 1024,
  }) {
    _metaDataFile = File(directory.path + '/metadata.json');
    final lruCacheDir = Directory(directory.path + '/cache');
    if (!lruCacheDir.existsSync()) {
      lruCacheDir.createSync(recursive: true);
    }
    _lruCache = DiskLruCache(
      directory: lruCacheDir,
      maxSize: maxSize,
      filesCount: 1,
    );
  }

  Future<CacheMetaData> getCacheMetaData(String key) async {
    await _loadMetaDataSync();
    if ((await _lruCache.get(key)) == null) {
      _metaData.remove(key);
      return null;
    }
    return _metaData[key];
  }

  Future<Stream<List<int>>> getCachedStream(String key) async {
    await _loadMetaDataSync();
    final cacheEntry = await _lruCache.get(key);
    if (cacheEntry == null) {
      throw NullThrownError();
    }
    final stream = cacheEntry.getStream(0);
    if (stream == null) {
      throw NullThrownError();
    }
    return stream;
  }

  Future<void> save(String key, StreamedResponse response) async {
    await _loadMetaDataSync();
    await _lock.synchronized(() async {
      final metaData = CacheMetaData.fromResponse(response);
      final editor = await _lruCache.edit(key);

      final stream = await editor.copyStream(0, response.stream);
      // The bytes has been written to disk at this point.
      await ByteStream(stream).toBytes();
      await editor.commit();

      assert(getCacheMetaData(key) != null);

      _metaData[key] = metaData;
    });
    await _saveMetaData();
  }

  Future<void> _saveMetaData() {
    return _lock.synchronized(() {
      final data = {};
      _metaData.forEach((key, value) {
        if (value != null) {
          data[key] = value.toMap();
        }
      });
      final jsonMetaData = json.encode(data);
      _metaDataFile.writeAsStringSync(jsonMetaData);
    });
  }

  Future<void> _loadMetaDataSync() async {
    if (_metaData != null) {
      return;
    }
    await _lock.synchronized(() {
      _metaData = {};
      if (!_metaDataFile.existsSync()) {
        return;
      }

      final jsonData = json.decode(_metaDataFile.readAsStringSync()) as Map;
      jsonData.forEach((key, value) {
        try {
          _metaData[key] = CacheMetaData.fromMap(value as Map);
        } catch (e) {
          // ignore
        }
      });
    });
  }

  Future<void> clear() async {
    await _loadMetaDataSync();
    await _lock.synchronized(() async {
      await _lruCache.clean();
      _metaData.clear();
    });
    await _saveMetaData();
  }
}

String createCacheKey(Uri uri) {
  return md5.convert(uri.toString().codeUnits).toString();
}
