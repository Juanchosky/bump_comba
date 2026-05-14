import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../services/premium_service.dart';
import '../services/dynamic_scraper_service.dart';
import '../services/xtream_service.dart';
import '../utils/security_utils.dart';
import '../models/m3u_item.dart';
import '../models/download_progress.dart';
import '../utils/normalization_utils.dart';
import '../services/watch_progress_service.dart';
import 'tmdb_service.dart';

export '../models/m3u_item.dart';
export '../models/download_progress.dart';
export '../utils/normalization_utils.dart';

// ===========================================================================
// SERVICE
// ===========================================================================

/// Model for a user-defined IPTV source (M3U or Xtream)
class M3USource {
  final String name;
  final String url; // Host or M3U URL
  final bool isCode;
  final String? originalInput;

  // Xtream Codes fields
  final String? username;
  final String? password;
  final String type; // 'm3u' or 'xtream'

  M3USource({
    required this.name,
    required this.url,
    this.isCode = false,
    this.originalInput,
    this.username,
    this.password,
    this.type = 'm3u',
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': SecurityUtils.obfuscate(url),
    'isCode': isCode,
    'originalInput':
        originalInput != null ? SecurityUtils.obfuscate(originalInput!) : null,
    'username': username != null ? SecurityUtils.obfuscate(username!) : null,
    'password': password != null ? SecurityUtils.obfuscate(password!) : null,
    'type': type,
  };

  factory M3USource.fromJson(Map<String, dynamic> json) => M3USource(
    name: json['name'] ?? '',
    url: SecurityUtils.deobfuscate(json['url'] ?? ''),
    isCode: json['isCode'] ?? false,
    originalInput:
        json['originalInput'] != null
            ? SecurityUtils.deobfuscate(json['originalInput'])
            : null,
    username:
        json['username'] != null
            ? SecurityUtils.deobfuscate(json['username'])
            : null,
    password:
        json['password'] != null
            ? SecurityUtils.deobfuscate(json['password'])
            : null,
    type: json['type'] ?? 'm3u',
  );
}

// ===========================================================================
// SERVICE
// ===========================================================================

/// Service for M3U parsing and Supabase integration.
///
/// CHANGES vs original:
///   PERF-1  — BytesBuilder replaces List-int accumulation in download
///   PERF-2  — search() moved to compute() isolate (unblocks UI thread)
///   PERF-3  — getRecentItems() result cached and invalidated on reload
///   PERF-4  — getSimilarItems() uses shuffle instead of random-attempt loop
///   ROBUST-1 — init() uses Completer to prevent concurrent double-init
///   ROBUST-2 — _processOutput() always rebuilds _searchNames
///   ROBUST-3 — clearCache() logs errors instead of swallowing them
///   ROBUST-4 — resolveM3UInput() validates constructed URLs
///   FEAT-1  — retryLoad() with configurable attempts + exponential backoff
///   FEAT-2  — like deduplication stored in SharedPreferences
///   FEAT-3  — getContentStats() returns aggregate stats for analytics/UI
///   FEAT-4  — DownloadProgress typed class instead of raw Function params
class M3UService extends ChangeNotifier {
  // ── Supabase credentials ─────────────────────────────────────────────────
  // SECURITY NOTE: Keys moved to .env file
  static String get _supabaseUrl =>
      dotenv.env['SUPABASE_URL'] ??
      const String.fromEnvironment(
        'SUPABASE_URL',
        defaultValue: 'https://inukqboqdvwtmmthjwrl.supabase.co',
      );
  static String get _supabaseAnonKey =>
      dotenv.env['SUPABASE_ANON_KEY'] ??
      const String.fromEnvironment(
        'SUPABASE_ANON_KEY',
        defaultValue:
            'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImludWtxYm9xZHZ3dG1tdGhqd3JsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzkyMzM3NDIsImV4cCI6MjA1NDgwOTc0Mn0.bWNkWIErT71tXchtxN9D83w-I--UIGOIzZKff3-X5V8',
      );

  // ── SharedPreferences keys ───────────────────────────────────────────────
  static const String _favoritesKey = 'm3u_favorites';
  static const String _cacheTimestampKey = 'm3u_cache_timestamp';
  static const String _cacheFileName = 'm3u_cache.txt';
  static const String _customCacheTimestampKey = 'm3u_custom_cache_timestamp';
  static const String _customCacheFileName = 'm3u_custom_cache.json';
  static const String _unifiedCacheTimestampKey = 'm3u_unified_cache_timestamp';
  static const String _unifiedCachePrefix = 'm3u_cache_unified_';
  static const String _m3uUrlKey = 'local_m3u_url';
  static const String _m3uUserKey = 'local_m3u_user';
  static const String _m3uPassKey = 'local_m3u_pass';
  static const String _m3uTypeKey = 'local_m3u_type';
  static const String _m3uSourcesKey = 'm3u_sources_list';
  static const String _activeSourceIndexKey = 'active_m3u_source_index';
  static const String _favoriteTipKey = 'show_favorite_tip';
  static const String _isUnifiedModeKey = 'is_unified_mode';
  static const String _logicVersionKey = 'm3u_logic_version';
  static const int _currentLogicVersion = 11;
  // FEAT-2: key prefix for liked content deduplication
  static const String _likedUrlsKey = 'm3u_liked_urls';
  static const String _failedLogosKey = 'm3u_failed_logos';
  static const String _favoriteItemsJsonKey = 'm3u_favorite_items_json';
  static const Duration _cacheDuration = Duration(minutes: 10);

  // ── Singleton ────────────────────────────────────────────────────────────
  static final M3UService _instance = M3UService._internal();
  factory M3UService() => _instance;
  M3UService._internal();

  // ── State ────────────────────────────────────────────────────────────────
  SharedPreferences? _prefs;
  SupabaseClient? _supabase;
  List<M3UItem> _items = [];
  List<M3UItem> _movies = [];
  List<M3UItem> _series = [];
  Set<String> _favorites = {};
  List<M3UItem> _favoriteItems = [];
  List<FilterRule> _filterRules = [];
  List<M3USource> _sources = [];
  int _activeSourceIndex = 0;
  bool _isUnifiedMode = false;
  String? _lastError;
  // FEAT-2: local set of liked URLs to prevent duplicate Supabase inserts
  Set<String> _likedUrls = {};
  Set<String> _failedLogos = {};
  Timer? _failedLogoDebouncer;

  // ── Performance caches ───────────────────────────────────────────────────
  List<String>? _cachedCategories;
  List<M3UItem>? _cachedLatestItems;
  Map<String, List<M3UItem>>? _categoryIndex;
  Map<String, M3UItem>? _urlIndex;
  Map<String, M3UItem>? _seriesNameIndex;
  // PERF-3: cache for getRecentItems() — invalidated on every content reload
  List<M3UItem>? _cachedRecentItems;
  // Session-level cache for recommendations — stays stable during session
  List<M3UItem>? _sessionRecommendedItems;
  // Cache for TMDB popular search matches
  List<M3UItem>? _cachedPopularTMDB;
  bool _isFetchingPopularTMDB = false;
  bool get isFetchingPopularTMDB => _isFetchingPopularTMDB;

  // ROBUST-1: Completer-based init guard (prevents concurrent double-init)
  Completer<void>? _initCompleter;

  // ── Public getters ───────────────────────────────────────────────────────
  List<M3UItem> get items => _items;
  List<M3UItem> get movies => _movies;
  List<M3UItem> get series => _series;
  List<M3UItem> get latestItems => _cachedLatestItems ?? [];
  List<String> get categories => _cachedCategories ?? [];
  List<M3USource> get sources => _sources;
  int get activeSourceIndex => _activeSourceIndex;
  bool get isUnifiedMode => _isUnifiedMode;
  String? get lastError => _lastError;
  bool get shouldShowFavoriteTip => _prefs?.getBool(_favoriteTipKey) ?? true;

  // ===========================================================================
  // INIT
  // ===========================================================================

  /// Initialize the service.
  ///
  /// ROBUST-1: Uses a Completer so concurrent calls await the same future
  /// instead of running duplicate initialisation logic in parallel.
  Future<void> init() async {
    if (_initCompleter != null) return _initCompleter!.future;

    _initCompleter = Completer<void>();
    try {
      _prefs = await SharedPreferences.getInstance();

      // Perform automated migration before loading data
      await _migrateToObfuscatedStorage();

      _loadFavorites();
      _loadLikedUrls(); // FEAT-2
      _loadFailedLogos();

      await initializeSupabase();
      _supabase = Supabase.instance.client;

      // Non-blocking remote config fetch
      _updateRemoteConfig();

      await _clearOldCache();
      await _loadSources();

      _isUnifiedMode = _prefs?.getBool(_isUnifiedModeKey) ?? false;
      if (_isUnifiedMode && !PremiumService().isPremium) {
        _isUnifiedMode = false;
        await _prefs?.setBool(_isUnifiedModeKey, false);
      }

      _initCompleter!.complete();
    } catch (e, stack) {
      // Allow re-init on failure
      final completer = _initCompleter!;
      _initCompleter = null;
      debugPrint('M3UService.init() failed: $e\n$stack');
      completer.completeError(e, stack);
      rethrow;
    }
  }

  /// Centralised Supabase initialisation.
  static Future<void> initializeSupabase() async {
    try {
      Supabase.instance.client;
    } catch (_) {
      await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);
    }
  }

  Future<void> _migrateToObfuscatedStorage() async {
    if (_prefs == null) return;

    // 1. Migrate active URL
    final url = _prefs!.getString(_m3uUrlKey);
    if (url != null && !SecurityUtils.isObfuscated(url)) {
      await _prefs!.setString(_m3uUrlKey, SecurityUtils.obfuscate(url));
    }

    // 2. Migrate sources list
    final sources = _prefs!.getStringList(_m3uSourcesKey);
    if (sources != null && sources.any((s) => !SecurityUtils.isObfuscated(s))) {
      final updatedSources =
          sources.map((s) => SecurityUtils.obfuscate(s)).toList();
      await _prefs!.setStringList(_m3uSourcesKey, updatedSources);
    }

    // 3. Migrate favorites list (keys)
    final favs = _prefs!.getStringList(_favoritesKey);
    if (favs != null && favs.any((f) => !SecurityUtils.isObfuscated(f))) {
      final updatedFavs = favs.map((f) => SecurityUtils.obfuscate(f)).toList();
      await _prefs!.setStringList(_favoritesKey, updatedFavs);
    }

    // 4. Migrate favorite items JSON
    final favItems = _prefs!.getString(_favoriteItemsJsonKey);
    if (favItems != null &&
        favItems.isNotEmpty &&
        !SecurityUtils.isObfuscated(favItems)) {
      await _prefs!.setString(
        _favoriteItemsJsonKey,
        SecurityUtils.obfuscate(favItems),
      );
    }

    // 5. Migrate new Xtream keys (Defense in depth)
    final user = _prefs!.getString(_m3uUserKey);
    if (user != null && !SecurityUtils.isObfuscated(user)) {
      await _prefs!.setString(_m3uUserKey, SecurityUtils.obfuscate(user));
    }
    final pass = _prefs!.getString(_m3uPassKey);
    if (pass != null && !SecurityUtils.isObfuscated(pass)) {
      await _prefs!.setString(_m3uPassKey, SecurityUtils.obfuscate(pass));
    }
  }

  // ===========================================================================
  // CACHE HELPERS
  // ===========================================================================

  Future<void> _clearOldCache() async {
    try {
      await _prefs?.remove('m3u_cached_content');
    } catch (e) {
      debugPrint('_clearOldCache error: $e');
    }
  }

  Future<File> _getCacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_cacheFileName');
  }

  Future<File> _getUnifiedCacheFile(int index) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_unifiedCachePrefix$index.txt');
  }

  Future<File> _getJsonCacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final suffix = _isUnifiedMode ? 'unified' : 'single_$_activeSourceIndex';
    return File('${dir.path}/m3u_parsed_cache_$suffix.json');
  }

  Future<File> _getCustomCacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_customCacheFileName');
  }

  Future<void> _saveJsonCache(List<M3UItem> items) async {
    try {
      final file = await _getJsonCacheFile();
      final securityKey =
          dotenv.env['SECURITY_KEY'] ?? 'bump_comba_v1_secure_layer_2026';
      final obfuscated = await compute(_encodeJsonCacheInBackground, {
        'items': items,
        'key': securityKey,
      });
      await file.writeAsString(obfuscated);
      await _prefs?.setInt(_logicVersionKey, _currentLogicVersion);

      // FIX: Guardar también el timestamp del caché para que _loadJsonCache()
      // y _isCacheExpired() funcionen correctamente con fuentes Xtream.
      // Sin esto, el caché JSON se guardaba pero sin timestamp → siempre
      // se consideraba expirado → re-descarga innecesaria en cada reinicio.
      final timestampKey =
          _isUnifiedMode ? _unifiedCacheTimestampKey : _cacheTimestampKey;
      await _prefs?.setInt(timestampKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('Error saving JSON cache: $e');
    }
  }

  @pragma('vm:entry-point')
  static String _encodeJsonCacheInBackground(Map<String, dynamic> data) {
    final items = data['items'] as List<M3UItem>;
    final key = data['key'] as String;
    final jsonStr = json.encode(items.map((i) => i.toMap()).toList());

    // Manual obfuscation to avoid dotenv dependency in isolate
    final bytes = utf8.encode(jsonStr);
    final keyBytes = utf8.encode(key);
    final result = List<int>.generate(bytes.length, (i) {
      return bytes[i] ^ keyBytes[i % keyBytes.length];
    });
    return 'obf:${base64.encode(result)}';
  }

  Future<List<M3UItem>?> _loadJsonCache({bool ignoreExpiration = false}) async {
    try {
      final savedVersion = _prefs?.getInt(_logicVersionKey) ?? 0;
      if (savedVersion < _currentLogicVersion) return null;

      if (!ignoreExpiration) {
        final cacheTimestamp = _prefs?.getInt(_cacheTimestampKey);
        if (cacheTimestamp == null ||
            DateTime.now().millisecondsSinceEpoch - cacheTimestamp >
                _cacheDuration.inMilliseconds) {
          // If expired and not ignoring expiration, return null to trigger network update
          return null;
        }
      }

      final file = await _getJsonCacheFile();
      if (!await file.exists()) return null;

      final raw = await file.readAsString();
      final securityKey =
          dotenv.env['SECURITY_KEY'] ?? 'bump_comba_v1_secure_layer_2026';
      return await compute(_decodeJsonCacheInBackground, {
        'raw': raw,
        'key': securityKey,
      });
    } catch (e) {
      debugPrint('Error loading JSON cache: $e');
      return null;
    }
  }

  // ===========================================================================
  // FAVORITES
  // ===========================================================================

  void _loadFavorites() {
    final favList = _prefs?.getStringList(_favoritesKey) ?? [];
    _favorites = favList.map((f) => SecurityUtils.deobfuscate(f)).toSet();

    final favItemsJson = _prefs?.getString(_favoriteItemsJsonKey);
    if (favItemsJson != null && favItemsJson.isNotEmpty) {
      try {
        final decryptedJson = SecurityUtils.deobfuscate(favItemsJson);
        final List<dynamic> decoded = json.decode(decryptedJson);
        _favoriteItems =
            decoded
                .map((e) => M3UItem.fromMap(e as Map<String, dynamic>))
                .toList();
      } catch (e) {
        debugPrint('Error loading favorite items JSON: $e');
        _favoriteItems = [];
      }
    } else {
      _favoriteItems = [];
    }
  }

  Future<void> _saveFavorites() async {
    // Obfuscate the list of keys
    final obfuscatedFavs =
        _favorites.map((f) => SecurityUtils.obfuscate(f)).toList();
    await _prefs?.setStringList(_favoritesKey, obfuscatedFavs);

    try {
      final jsonStr = json.encode(
        _favoriteItems.map((i) => i.toMap()).toList(),
      );
      final encryptedJson = SecurityUtils.obfuscate(jsonStr);
      await _prefs?.setString(_favoriteItemsJsonKey, encryptedJson);
    } catch (e) {
      debugPrint('Error saving favorite items JSON: $e');
    }
  }

  /// Toggle favorite status for an item.
  Future<void> toggleFavorite(M3UItem item) async {
    final key = '${item.name}_${item.url}';
    if (_favorites.contains(key)) {
      _favorites.remove(key);
      item.isFavorite = false;
      _favoriteItems.removeWhere(
        (i) => i.url == item.url && i.name == item.name,
      );
    } else {
      if (item.isLive) {
        final liveCount = _favoriteItems.where((i) => i.isLive).length;
        if (!PremiumService().canAddLiveFavorite(liveCount)) {
          throw Exception(
            'Límite de canales en Mi Lista alcanzado (máx. 4). ¡Hazte Premium!',
          );
        }
      } else {
        final contentCount = _favoriteItems.where((i) => !i.isLive).length;
        if (!PremiumService().canAddFavorite(contentCount)) {
          throw Exception(
            'Límite de películas/series en Mi Lista alcanzado (máx. 5). ¡Hazte Premium!',
          );
        }
      }
      _favorites.add(key);
      item.isFavorite = true;
      _favoriteItems.add(item);
    }
    await _saveFavorites();
  }

  List<M3UItem> getFavorites() => _favoriteItems;

  Future<void> dismissFavoriteTip() async {
    await _prefs?.setBool(_favoriteTipKey, false);
  }

  // ===========================================================================
  // LIKED URLS — FEAT-2
  // ===========================================================================

  void _loadLikedUrls() {
    _likedUrls = (_prefs?.getStringList(_likedUrlsKey) ?? []).toSet();
  }

  Future<void> _saveLikedUrls() async {
    await _prefs?.setStringList(_likedUrlsKey, _likedUrls.toList());
  }

  // ===========================================================================
  // FAILED LOGOS
  // ===========================================================================

  void _loadFailedLogos() {
    _failedLogos = (_prefs?.getStringList(_failedLogosKey) ?? []).toSet();
  }

  Future<void> _saveFailedLogos() async {
    await _prefs?.setStringList(_failedLogosKey, _failedLogos.toList());
  }

  /// Refined filtering: remove items with null/empty logos OR those known to fail.
  List<M3UItem> filterValidItems(List<M3UItem> items) {
    // No filtramos nada por falta de logo; usamos el placeholder con título.
    return items;
  }

  /// Mark a logo as failed. Persists to disk and notifies listeners with debouncing.
  void reportFailedLogo(String logo) {
    if (_failedLogos.contains(logo)) return;
    _failedLogos.add(logo);
    _saveFailedLogos();

    // Debounce notification to avoid jarring UI shifts during massive load failures
    _failedLogoDebouncer?.cancel();
    _failedLogoDebouncer = Timer(const Duration(milliseconds: 600), () {
      notifyListeners();
    });
  }

  // ===========================================================================
  // SOURCES
  // ===========================================================================

  Future<void> _loadSources() async {
    final sourcesJson = _prefs?.getStringList(_m3uSourcesKey);
    if (sourcesJson != null) {
      _sources =
          sourcesJson.map((s) {
            final decrypted = SecurityUtils.deobfuscate(s);
            return M3USource.fromJson(json.decode(decrypted));
          }).toList();
    }
    _activeSourceIndex = _prefs?.getInt(_activeSourceIndexKey) ?? 0;

    final rawUrl = _prefs?.getString(_m3uUrlKey);
    final oldUrl = rawUrl != null ? SecurityUtils.deobfuscate(rawUrl) : null;

    if (_sources.isEmpty && oldUrl != null && oldUrl.isNotEmpty) {
      _sources.add(M3USource(name: 'Mi Fuente', url: oldUrl));
      await _saveSources();
    }
  }

  Future<void> _saveSources() async {
    final sourcesJson =
        _sources.map((s) {
          final encoded = json.encode(s.toJson());
          return SecurityUtils.obfuscate(encoded);
        }).toList();
    await _prefs?.setStringList(_m3uSourcesKey, sourcesJson);
    await _prefs?.setInt(_activeSourceIndexKey, _activeSourceIndex);
  }

  Future<void> addSource(
    String name,
    String url, {
    bool isCode = false,
    String? originalInput,
    String? username,
    String? password,
    String type = 'm3u',
  }) async {
    if (!PremiumService().isPremium && _sources.length >= 3) {
      throw Exception(
        'Límite alcanzado. Los usuarios gratuitos pueden tener máximo 3 listas. ¡Hazte Premium!',
      );
    }
    _sources.add(
      M3USource(
        name: name,
        url: url,
        isCode: isCode,
        originalInput: originalInput,
        username: username,
        password: password,
        type: type,
      ),
    );
    await _saveSources();
  }

  Future<void> removeSource(int index) async {
    if (index < 0 || index >= _sources.length) return;
    _sources.removeAt(index);
    if (_activeSourceIndex >= _sources.length) {
      _activeSourceIndex = _sources.isNotEmpty ? _sources.length - 1 : 0;
    }
    await _saveSources();
    await clearCache();
  }

  Future<void> setActiveSource(int index) async {
    if (index < 0 || index >= _sources.length) return;
    _activeSourceIndex = index;
    await _saveSources();
    await clearCache();
  }

  Future<void> setUnifiedMode(bool value) async {
    if (value && !PremiumService().isPremium) return;
    _isUnifiedMode = value;
    await _prefs?.setBool(_isUnifiedModeKey, value);
    await clearCache();
  }

  M3USource? getActiveSource() {
    if (_sources.isNotEmpty &&
        _activeSourceIndex >= 0 &&
        _activeSourceIndex < _sources.length) {
      return _sources[_activeSourceIndex];
    }
    return null;
  }

  Future<String?> getM3UUrl() async {
    if (_sources.isNotEmpty &&
        _activeSourceIndex >= 0 &&
        _activeSourceIndex < _sources.length) {
      return _sources[_activeSourceIndex].url;
    }
    final raw = _prefs?.getString(_m3uUrlKey);
    return raw != null ? SecurityUtils.deobfuscate(raw) : null;
  }

  Future<void> setLocalM3UUrl(
    String url, {
    bool isCode = false,
    String? originalInput,
    String? username,
    String? password,
    String type = 'm3u',
  }) async {
    await _prefs?.setString(_m3uUrlKey, SecurityUtils.obfuscate(url));
    await _prefs?.setString(_m3uTypeKey, type);
    if (username != null) {
      await _prefs?.setString(_m3uUserKey, SecurityUtils.obfuscate(username));
    } else {
      await _prefs?.remove(_m3uUserKey);
    }
    if (password != null) {
      await _prefs?.setString(_m3uPassKey, SecurityUtils.obfuscate(password));
    } else {
      await _prefs?.remove(_m3uPassKey);
    }

    if (_sources.isEmpty) {
      _sources.add(
        M3USource(
          name: 'Mi Fuente',
          url: url,
          isCode: isCode,
          originalInput: originalInput,
          username: username,
          password: password,
          type: type,
        ),
      );
      _activeSourceIndex = 0;
    } else {
      if (_sources.length == 1 || _sources[0].name == 'Mi Fuente') {
        _sources[0] = M3USource(
          name: 'Mi Fuente',
          url: url,
          isCode: isCode,
          originalInput: originalInput,
          username: username,
          password: password,
          type: type,
        );
      } else {
        _sources.add(
          M3USource(
            name: 'Nueva Fuente',
            url: url,
            isCode: isCode,
            originalInput: originalInput,
            username: username,
            password: password,
            type: type,
          ),
        );
        _activeSourceIndex = _sources.length - 1;
      }
    }
    await _saveSources();
    await clearCache();
  }

  // ===========================================================================
  // REMOTE CONFIG / SUPABASE
  // ===========================================================================

  Future<void> _updateRemoteConfig() async {
    try {
      final filtersData = await _supabase!
          .from('m3u_filters')
          .select('category, regex_pattern, priority')
          .eq('is_active', true)
          .order('priority', ascending: true);

      _filterRules =
          (filtersData as List).map((e) => FilterRule.fromJson(e)).toList();
    } catch (e) {
      debugPrint('Error loading remote filters: $e');
    }
  }

  Future<List<CloudSource>> fetchCloudSources() async {
    try {
      if (_supabase == null) return [];
      final data = await _supabase!
          .from('m3u_sources')
          .select()
          .eq('is_active', true);
      final allSources =
          (data as List).map((e) => CloudSource.fromJson(e)).toList();
      final now = DateTime.now();
      return allSources.where((s) {
        final visibleUntil = s.visibleUntil;
        if (visibleUntil != null && visibleUntil.isBefore(now)) {
          return false;
        }
        return true;
      }).toList();
    } catch (e) {
      debugPrint('Error fetching cloud sources: $e');
      return [];
    }
  }

  Future<String?> fetchRemoteConfiguration(String key) async {
    if (_supabase == null) return null;
    try {
      final data =
          await _supabase!
              .from('sys_config')
              .select('value')
              .eq('key', key)
              .eq('is_active', true)
              .maybeSingle();
      if (data != null && data['value'] != null) {
        return data['value'] as String;
      }
    } catch (e) {
      debugPrint('Error fetching config: $e');
    }
    return null;
  }

  /// ROBUST-4: resolveM3UInput validates constructed URLs before returning.
  /// Result contains the resolved URL and whether it was a code match.
  Future<
    ({
      String? url,
      bool isCode,
      String? username,
      String? password,
      String type,
    })
  >
  resolveM3UInput(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return (
        url: null,
        isCode: false,
        username: null,
        password: null,
        type: 'm3u',
      );
    }

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      try {
        final uri = Uri.parse(trimmed);
        if (uri.queryParameters.containsKey('username') &&
            uri.queryParameters.containsKey('password')) {
          final host =
              '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
          return (
            url: host,
            isCode: false,
            username: uri.queryParameters['username'],
            password: uri.queryParameters['password'],
            type: 'xtream',
          );
        }
      } catch (_) {}
      return (
        url: trimmed,
        isCode: false,
        username: null,
        password: null,
        type: 'm3u',
      );
    }

    if (trimmed.endsWith('.m3u') ||
        trimmed.endsWith('.m3u8') ||
        trimmed.contains('/') ||
        trimmed.contains('.com') ||
        trimmed.contains('.net') ||
        trimmed.contains('.org') ||
        trimmed.contains('.tv') ||
        trimmed.contains('.lat') ||
        trimmed.contains('.io')) {
      // ROBUST-4: validate before returning
      final candidate = 'http://$trimmed';
      final uri = Uri.tryParse(candidate);
      if (uri != null && uri.hasAuthority && uri.host.isNotEmpty) {
        return (
          url: candidate,
          isCode: false,
          username: null,
          password: null,
          type: 'm3u',
        );
      }
      return (
        url: null,
        isCode: false,
        username: null,
        password: null,
        type: 'm3u',
      );
    }

    // 1. Check Load Balancer first
    try {
      if (_supabase != null) {
        final List<dynamic> balancerData = await _supabase!
            .from('m3u_load_balancer')
            .select(
              'id, value, current_connections, max_connections, type, username, password',
            )
            .eq('key', trimmed)
            .eq('is_active', true);

        if (balancerData.isNotEmpty) {
          balancerData.sort((a, b) {
            final double ratioA =
                (a['current_connections'] ?? 0) / (a['max_connections'] ?? 1);
            final double ratioB =
                (b['current_connections'] ?? 0) / (b['max_connections'] ?? 1);
            return ratioA.compareTo(ratioB);
          });

          final bestMatch = balancerData.first;
          final String bestUrl = bestMatch['value'] as String;
          final String bestId = bestMatch['id'] as String;
          final String bestType =
              (bestMatch['type'] ?? 'm3u').toString().toLowerCase();

          _incrementLoadBalancerConnection(bestId);

          // Second-pass: If it's a code but the 'value' contains a composite URL
          // like http://host:port/get.php?username=XXX... parse it.
          if (bestUrl.startsWith('http') && bestUrl.contains('username=')) {
            try {
              final uri = Uri.parse(bestUrl);
              return (
                url:
                    '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}',
                isCode: true,
                username: uri.queryParameters['username'],
                password: uri.queryParameters['password'],
                type: 'xtream',
              );
            } catch (_) {}
          }

          return (
            url: bestUrl,
            isCode: true,
            username: bestMatch['username']?.toString(),
            password: bestMatch['password']?.toString(),
            type: bestType,
          );
        }
      }
    } catch (e) {
      debugPrint('Error in load balancer: $e');
    }

    final remoteUrl = await fetchRemoteConfiguration(trimmed);
    return (
      url: remoteUrl,
      isCode: remoteUrl != null,
      username: null,
      password: null,
      type: 'm3u',
    );
  }

  /// Fetch personal content (movies/series) from Supabase.
  Future<List<M3UItem>> fetchCustomContent({bool forceRefresh = false}) async {
    if (_supabase == null) return [];

    // Local Cache evaluation
    if (!forceRefresh) {
      final cacheTimestamp = _prefs?.getInt(_customCacheTimestampKey);
      if (cacheTimestamp != null &&
          DateTime.now().millisecondsSinceEpoch - cacheTimestamp <
              _cacheDuration.inMilliseconds) {
        try {
          final file = await _getCustomCacheFile();
          if (await file.exists()) {
            final raw = await file.readAsString();
            final securityKey =
                dotenv.env['SECURITY_KEY'] ?? 'bump_comba_v1_secure_layer_2026';
            final cachedItems = await compute(_decodeJsonCacheInBackground, {
              'raw': raw,
              'key': securityKey,
            });
            if (cachedItems.isNotEmpty) {
              debugPrint(
                'Loaded ${cachedItems.length} custom items from local cache',
              );
              return cachedItems;
            }
          }
        } catch (e) {
          debugPrint('Error loading custom cache: $e');
        }
      }
    }

    try {
      final List<dynamic> list = [];
      bool hasMore = true;
      int from = 0;
      const int batchSize = 1000;

      while (hasMore) {
        final response = await _supabase!
            .from('custom_content')
            .select()
            .eq('is_active', true)
            .range(from, from + batchSize - 1);

        final List<dynamic> batch = response as List;
        list.addAll(batch);

        if (batch.length < batchSize) {
          hasMore = false;
        } else {
          from += batchSize;
        }
      }

      final Map<String, List<Map<String, dynamic>>> episodesMap = {};
      final List<Map<String, dynamic>> seriesRows = [];
      final List<Map<String, dynamic>> movieRows = [];

      for (final dynamic rawRow in list) {
        if (rawRow is! Map) continue;
        final row = Map<String, dynamic>.from(rawRow);

        final type = (row['type'] ?? 'movie').toString().toLowerCase();
        if (type == 'episode') {
          final pId = row['parent_id']?.toString();
          if (pId != null) {
            episodesMap.putIfAbsent(pId, () => []).add(row);
          }
        } else if (type == 'series') {
          seriesRows.add(row);
        } else {
          movieRows.add(row);
        }
      }

      final List<M3UItem> finalItems = [];

      // Add Movies
      for (final row in movieRows) {
        final name = (row['title'] ?? '').toString();
        final url = (row['video_url'] ?? '').toString();
        final rawCat = (row['category'] ?? 'Recomendados').toString();

        // Normalize Category
        final category =
            rawCat.isNotEmpty
                ? rawCat[0].toUpperCase() + rawCat.substring(1).toLowerCase()
                : 'Recomendados';

        final isDynamic = DynamicScraperService().isSupported(url);

        finalItems.add(
          M3UItem(
            name: name,
            url: url,
            logo: row['thumbnail_url']?.toString(),
            category: category,
            isFavorite: _favorites.contains('${name}_$url'),
            isLive: false,
            isDynamic: isDynamic,
            sourceName: 'Supabase',
          ),
        );
      }

      // Add Series with episodes
      for (final row in seriesRows) {
        final sId = row['id']?.toString() ?? '';
        final name = (row['title'] ?? '').toString();
        final rawCat = (row['category'] ?? 'Recomendados').toString();

        final category =
            rawCat.isNotEmpty
                ? rawCat[0].toUpperCase() + rawCat.substring(1).toLowerCase()
                : 'Recomendados';

        final url = (row['video_url'] ?? '').toString();
        final isDynamic = DynamicScraperService().isSupported(url);

        final sEpisodes = <M3UItem>[];
        final epRows = episodesMap[sId] ?? [];

        for (final ep in epRows) {
          final epName = (ep['title'] ?? '').toString();
          final epUrl = (ep['video_url'] ?? '').toString();
          final epIsDynamic = DynamicScraperService().isSupported(epUrl);

          sEpisodes.add(
            M3UItem(
              name: epName,
              url: epUrl,
              logo:
                  ep['thumbnail_url']?.toString() ??
                  row['thumbnail_url']?.toString(),
              category: category,
              seriesName: name,
              seasonNumber: int.tryParse(ep['season']?.toString() ?? ''),
              episodeNumber: int.tryParse(ep['episode']?.toString() ?? ''),
              isLive: false,
              isDynamic: epIsDynamic,
              sourceName: 'Supabase',
            ),
          );
        }

        // Sort episodes by season and number
        sEpisodes.sort((a, b) {
          if (a.seasonNumber != b.seasonNumber) {
            return (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
          }
          return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
        });

        finalItems.add(
          M3UItem(
            name: name,
            url: '', // Header doesn't have a URL
            logo: row['thumbnail_url']?.toString(),
            category: category,
            isFavorite: _favorites.contains('${name}_'),
            episodes: sEpisodes,
            seriesName: name,
            isSeries: true,
            isLive: false,
            isDynamic: isDynamic,
            sourceName: 'Supabase',
          ),
        );
      }

      debugPrint('Loaded ${finalItems.length} custom items from Supabase');

      // Save custom items to JSON Cache
      try {
        final file = await _getCustomCacheFile();
        final securityKey =
            dotenv.env['SECURITY_KEY'] ?? 'bump_comba_v1_secure_layer_2026';
        final obfuscated = await compute(_encodeJsonCacheInBackground, {
          'items': finalItems,
          'key': securityKey,
        });
        await file.writeAsString(obfuscated);
        await _prefs?.setInt(
          _customCacheTimestampKey,
          DateTime.now().millisecondsSinceEpoch,
        );
      } catch (e) {
        debugPrint('Error saving custom cache: $e');
      }

      return finalItems;
    } catch (e, stack) {
      debugPrint('Error fetching custom content: $e\n$stack');
      _lastError = 'Error cargando contenido personal: $e';
      return [];
    }
  }

  /// Re-scrapes metadata for a dynamic item using the DynamicScraperService.
  Future<M3UItem> refreshDynamicItem(M3UItem item) async {
    if (!item.isDynamic) return item;

    try {
      final meta = await DynamicScraperService().scrapeMetadata(item.url);
      if (meta != null) {
        return item.copyWith(
          name: meta.title,
          logo: meta.thumbnailUrl ?? item.logo,
          episodes: meta.episodes,
        );
      }
    } catch (e) {
      debugPrint('Error refreshing dynamic item: $e');
    }
    return item;
  }

  Future<void> _incrementLoadBalancerConnection(String id) async {
    try {
      if (_supabase != null) {
        await _supabase!.rpc(
          'increment_m3u_connections',
          params: {'target_id': id},
        );
      }
    } catch (e) {
      debugPrint('Error incrementing connections: $e');
    }
  }

  bool isValidUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.hasAbsolutePath && uri.hasAuthority;
  }

  bool isCommunityFeatureVisible(int userCoins, DateTime installDate) {
    final hoursSinceInstall = DateTime.now().difference(installDate).inHours;
    if (hoursSinceInstall < 24) return false;
    if (userCoins < 1200) return false;
    return true;
  }

  // ===========================================================================
  // CONTENT LOADING
  // ===========================================================================

  /// Forces loading from local cache only, ignoring the expiration timestamp — PERF-2.
  /// Used for near-instant UI restoration (Netflix style).
  Future<bool> loadFromCache() async {
    final filtersMap =
        _filterRules
            .map((f) => {'category': f.category, 'regex': f.regexPattern})
            .toList();

    // 1. Try JSON cache first (best case)
    final cachedItems = await _loadJsonCache(ignoreExpiration: true);
    if (cachedItems != null && cachedItems.isNotEmpty) {
      final custom = await fetchCustomContent(forceRefresh: false);
      await _indexItems([...custom, ...cachedItems]);
      return true;
    }

    // 2. Try raw M3U cache file (fallback)
    final cacheFile = await _getCacheFile();
    if (await cacheFile.exists()) {
      try {
        final cachedBytes = await cacheFile.readAsBytes();
        final sourceName = _activeSourceName();
        final custom = await fetchCustomContent(forceRefresh: false);
        return _processOutput(
          await compute(
            parseM3UInBackground,
            IsolateInput(
              cachedBytes,
              _favorites.toList(),
              filtersMap,
              sourceName,
            ),
          ),
          custom,
        );
      } catch (e) {
        debugPrint('Error loading raw cache: $e');
      }
    }

    return false;
  }

  /// Load and parse M3U content.
  ///
  /// Use [onProgress] (typed [DownloadProgress]) for download feedback — FEAT-4.
  Future<bool> loadM3UContent({
    bool forceRefresh = false,
    bool useRetry = false,
    int retryAttempts = 3,
    void Function(DownloadProgress)? onProgress,
  }) async {
    _lastError = null;
    try {
      // PERF: Si ya hay items y el caché NO ha expirado, devolvemos true inmediatamente
      final bool isExpired = _isCacheExpired();
      if (_items.isNotEmpty && !forceRefresh && !isExpired) {
        return true;
      }

      // Si el contenido está vacío o el caché expiró o se forzó refresh,
      // re-resolvemos los códigos del Load Balancer para asegurar que apuntamos
      // al servidor más actualizado y disponible.
      if (_items.isEmpty || isExpired || forceRefresh) {
        await _reResolveCodesIfNeeded();
      }

      final filtersMap =
          _filterRules
              .map((f) => {'category': f.category, 'regex': f.regexPattern})
              .toList();

      if (useRetry) {
        return await retryLoad(
          attempts: retryAttempts,
          forceRefresh: forceRefresh || isExpired,
          onProgress: onProgress,
        );
      }

      if (_isUnifiedMode) {
        return await _loadUnified(filtersMap, forceRefresh, onProgress);
      } else {
        return await _loadSingle(filtersMap, forceRefresh, onProgress);
      }
    } catch (e, stack) {
      _lastError = 'Error inesperado: $e';
      debugPrint('Error loading M3U: $e\n$stack');
      return false;
    }
  }

  /// FEAT-1: Retry wrapper around loadM3UContent with exponential back-off.
  ///
  /// Example:
  ///   final ok = await service.retryLoad(attempts: 3);
  Future<bool> retryLoad({
    int attempts = 3,
    Duration initialDelay = const Duration(seconds: 2),
    bool forceRefresh = false,
    void Function(DownloadProgress)? onProgress,
  }) async {
    for (int i = 0; i < attempts; i++) {
      final ok = await loadM3UContent(
        forceRefresh: forceRefresh || i > 0,
        onProgress: onProgress,
      );
      if (ok) return true;

      if (i < attempts - 1) {
        final delay = initialDelay * (1 << i); // 2s → 4s → 8s
        debugPrint(
          'M3U load attempt ${i + 1} failed ($_lastError). '
          'Retrying in ${delay.inSeconds}s…',
        );
        await Future.delayed(delay);
      }
    }
    debugPrint('M3U load failed after $attempts attempts.');
    return false;
  }

  Future<bool> _loadUnified(
    List<Map<String, dynamic>> filtersMap,
    bool forceRefresh,
    void Function(DownloadProgress)? onProgress,
  ) async {
    if (_sources.isEmpty) {
      _lastError = 'No hay fuentes configuradas en el Modo Unificado.';
      return false;
    }

    final unifiedCacheTimestamp = _prefs?.getInt(_unifiedCacheTimestampKey);
    final bool hasValidUnifiedCache =
        !forceRefresh &&
        unifiedCacheTimestamp != null &&
        DateTime.now().millisecondsSinceEpoch - unifiedCacheTimestamp <
            _cacheDuration.inMilliseconds;

    if (hasValidUnifiedCache) {
      final cachedItems = await _loadJsonCache();
      if (cachedItems != null && cachedItems.isNotEmpty) {
        final custom = await fetchCustomContent(forceRefresh: forceRefresh);
        await _indexItems([...custom, ...cachedItems]);
        return true;
      }
    }

    List<M3UItem> allRawItems = [];

    for (int i = 0; i < _sources.length; i++) {
      final source = _sources[i];

      if (source.type == 'xtream') {
        final xtreamItems = await _fetchXtreamItems(
          source,
          forceRefresh,
          onProgress: onProgress,
        );
        allRawItems.addAll(xtreamItems);
        continue;
      }

      Uint8List? sourceBytes;

      if (hasValidUnifiedCache) {
        final cacheFile = await _getUnifiedCacheFile(i);
        if (await cacheFile.exists()) {
          sourceBytes = await cacheFile.readAsBytes();
        }
      }

      if (sourceBytes == null) {
        sourceBytes = await _fetchSourceBytes(source.url, onProgress);
        if (sourceBytes != null) {
          try {
            final cacheFile = await _getUnifiedCacheFile(i);
            await cacheFile.writeAsBytes(sourceBytes);
          } catch (e) {
            debugPrint('Error saving unified cache for source $i: $e');
          }
        }
      }

      if (sourceBytes != null) {
        final output = await compute(
          parseM3UInBackground,
          IsolateInput(
            sourceBytes,
            _favorites.toList(),
            filtersMap,
            source.name,
          ),
        );
        allRawItems.addAll(output.items);
      }
    }

    await _prefs?.setInt(
      _unifiedCacheTimestampKey,
      DateTime.now().millisecondsSinceEpoch,
    );

    // 1. Fetch custom content and merge
    final customItems = await fetchCustomContent(forceRefresh: forceRefresh);
    final allItems = [...customItems, ...allRawItems];

    // 2. Full background indexing
    await _indexItems(allItems);

    // 3. Save to JSON cache for future instant loads
    _saveJsonCache(allRawItems);

    return true;
  }

  Future<bool> _loadSingle(
    List<Map<String, dynamic>> filtersMap,
    bool forceRefresh,
    void Function(DownloadProgress)? onProgress,
  ) async {
    final activeSource =
        _sources.isNotEmpty && _activeSourceIndex < _sources.length
            ? _sources[_activeSourceIndex]
            : null;

    if (activeSource?.type == 'xtream') {
      if (!forceRefresh) {
        final cachedItems = await _loadJsonCache();
        if (cachedItems != null && cachedItems.isNotEmpty) {
          final custom = await fetchCustomContent(forceRefresh: forceRefresh);
          await _indexItems([...custom, ...cachedItems]);
          return true;
        }
      }

      final items = await _fetchXtreamItems(
        activeSource!,
        forceRefresh,
        onProgress: onProgress,
      );

      // FIX: Si la descarga de red devuelve lista vacía (timeout, error, etc.),
      // no sobreescribir el contenido existente. Intentar usar el caché como
      // fallback para evitar pantallas en blanco al reiniciar la app.
      if (items.isEmpty) {
        debugPrint('Xtream fetch returned empty — falling back to cache');
        final fallback = await _loadJsonCache(ignoreExpiration: true);
        if (fallback != null && fallback.isNotEmpty) {
          final custom = await fetchCustomContent(forceRefresh: false);
          await _indexItems([...custom, ...fallback]);
          return true;
        }
        // Si tampoco hay caché, mantener los items actuales si existen
        if (_items.isNotEmpty) return true;
        return false;
      }

      final custom = await fetchCustomContent(forceRefresh: forceRefresh);
      await _indexItems([...custom, ...items]);

      // Guardar en cache para la próxima vez
      _saveJsonCache(items);
      return true;
    }

    final cacheFile = await _getCacheFile();
    if (!forceRefresh) {
      final cacheTimestamp = _prefs?.getInt(_cacheTimestampKey);
      if (cacheTimestamp != null &&
          DateTime.now().millisecondsSinceEpoch - cacheTimestamp <
              _cacheDuration.inMilliseconds) {
        // Try JSON cache (MUCH faster)
        final cachedItems = await _loadJsonCache();
        if (cachedItems != null && cachedItems.isNotEmpty) {
          final custom = await fetchCustomContent(forceRefresh: forceRefresh);
          await _indexItems([...custom, ...cachedItems]);
          return true;
        }

        // Fallback to raw M3U parsing
        if (await cacheFile.exists()) {
          final cachedBytes = await cacheFile.readAsBytes();
          final sourceName = _activeSourceName();
          final custom = await fetchCustomContent(forceRefresh: forceRefresh);
          return _processOutput(
            await compute(
              parseM3UInBackground,
              IsolateInput(
                cachedBytes,
                _favorites.toList(),
                filtersMap,
                sourceName,
              ),
            ),
            custom,
          );
        }
      }
    }

    final m3uUrl = await getM3UUrl();
    if (m3uUrl == null || m3uUrl.isEmpty) {
      _lastError = 'No se ha configurado ninguna URL M3U.';
      return false;
    }

    final bodyBytes = await _fetchSourceBytes(m3uUrl, onProgress);
    if (bodyBytes == null) return false;

    // Cache raw body
    await cacheFile.writeAsBytes(bodyBytes);
    await _prefs?.setInt(
      _cacheTimestampKey,
      DateTime.now().millisecondsSinceEpoch,
    );

    final custom = await fetchCustomContent(forceRefresh: forceRefresh);
    return _processOutput(
      await compute(
        parseM3UInBackground,
        IsolateInput(
          bodyBytes,
          _favorites.toList(),
          filtersMap,
          _activeSourceName(),
        ),
      ),
      custom,
    );
  }

  Future<List<M3UItem>> _fetchXtreamItems(
    M3USource source,
    bool forceRefresh, {
    void Function(DownloadProgress)? onProgress,
  }) async {
    try {
      final host = source.url;
      final user = source.username ?? '';
      final pass = source.password ?? '';

      if (user.isEmpty || pass.isEmpty) return [];

      final xtream = XtreamService();

      int liveBytes = 0;
      int vodBytes = 0;
      int seriesBytes = 0;

      void notify() {
        onProgress?.call(
          DownloadProgress(liveBytes + vodBytes + seriesBytes, null),
        );
      }

      // Parallel fetch for Live, VOD and Series with tracking
      final results = await Future.wait([
        xtream.fetchLiveStreams(
          host,
          user,
          pass,
          onProgress: (p) {
            liveBytes = p.receivedBytes;
            notify();
          },
        ),
        xtream.fetchVodStreams(
          host,
          user,
          pass,
          onProgress: (p) {
            vodBytes = p.receivedBytes;
            notify();
          },
        ),
        xtream.fetchSeries(
          host,
          user,
          pass,
          onProgress: (p) {
            seriesBytes = p.receivedBytes;
            notify();
          },
        ),
      ]);

      final allItems = results.expand((x) => x).toList();

      // EFFICIENCY: Pre-index existing favorites for O(1) lookup
      final existingFavUrls = _favoriteItems.map((f) => f.url).toSet();

      for (var item in allItems) {
        final key = '${item.name}_${item.url}';
        if (_favorites.contains(key)) {
          item.isFavorite = true;
          if (!existingFavUrls.contains(item.url)) {
            _favoriteItems.add(item);
            existingFavUrls.add(item.url);
          }
        }
      }

      return allItems;
    } catch (e) {
      debugPrint('Error fetching Xtream items: $e');
      return [];
    }
  }

  String _activeSourceName() {
    if (_activeSourceIndex >= 0 && _activeSourceIndex < _sources.length) {
      return _sources[_activeSourceIndex].name;
    }
    return 'Local';
  }

  // ===========================================================================
  // DOWNLOAD — PERF-1
  // ===========================================================================

  /// Download bytes from [url] using BytesBuilder (avoids repeated List copies).
  Future<Uint8List?> _fetchSourceBytes(
    String url,
    void Function(DownloadProgress)? onProgress,
  ) async {
    try {
      final headers = {
        'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
        'Accept':
            'application/x-mpegURL, application/vnd.apple.mpegurl, text/plain, */*',
        'Accept-Encoding': 'gzip, deflate',
        'Referer': url.startsWith('http') ? Uri.parse(url).origin : '',
      };

      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(url));
        request.headers.addAll(headers);

        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 451) {
          _lastError =
              'Este servidor de lista está bloqueado por tu proveedor de internet (ISP) en tu región (Código 451). Usa una VPN para conectarte o prueba con otra red (ej. datos móviles).';
          return null;
        } else if (response.statusCode < 200 || response.statusCode >= 300) {
          _lastError = 'Error del servidor (Código ${response.statusCode}).';
          return null;
        }

        final expectedBytes = response.contentLength ?? -1;
        int receivedBytes = 0;
        // PERF-1: BytesBuilder avoids intermediate List<int> copy per chunk
        // ignore: deprecated_export_use
        final builder = BytesBuilder(copy: false);

        await response.stream
            .forEach((chunk) {
              builder.add(chunk);
              receivedBytes += chunk.length;
              onProgress?.call(
                DownloadProgress(
                  receivedBytes,
                  expectedBytes > 0 ? expectedBytes : null,
                ),
              );
            })
            .timeout(const Duration(seconds: 300));

        return builder.takeBytes();
      } finally {
        client.close();
      }
    } on http.ClientException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('connection refused')) {
        _lastError =
            'Conexión rechazada por el servidor. Esto puede ser por saturación o bloqueo regional.';
      } else if (msg.contains('connection closed')) {
        _lastError = 'Conexión cerrada inesperadamente por el servidor.';
      } else {
        _lastError = 'Error de red: ${e.message}';
      }
      return null;
    } on SocketException catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('connection refused')) {
        _lastError =
            'Conexión rechazada (Connection refused). El servidor está saturado o tu ISP lo bloquea.';
      } else {
        _lastError =
            'Sin conexión o el servidor no responde (SocketException).';
      }
      return null;
    } on TimeoutException {
      _lastError =
          'Tiempo de espera agotado. El enlace es muy lento o no responde.';
      return null;
    } catch (e) {
      _lastError = 'Error al descargar la lista: $e';
      return null;
    }
  }

  // ===========================================================================
  // OUTPUT PROCESSING — ROBUST-2
  // ===========================================================================

  bool _processOutput(IsolateOutput output, List<M3UItem> customItems) {
    // Merge custom items with M3U items
    final combinedItems = [...customItems, ...output.items];

    // Update global state via a unified indexing call.
    // scheduleRecentCompute: false porque _processOutput ya tiene su propio
    // Future.delayed más abajo que hace el mismo cómputo. Evita duplicación.
    _indexItems(combinedItems, scheduleRecentCompute: false);

    // Refresh other fields from output (things that don't need merging or are already processed)
    _cachedLatestItems = output.latestItems;
    _cachedRecentItems = null;

    // Sync _favoriteItems with newly parsed items
    final Map<String, M3UItem> currentItemsMap = {
      for (var i in _items)
        (i.isSeries ? '${i.name}_' : '${i.name}_${i.url}'): i,
    };

    // Update existing favorite items with fresh data from M3U if available
    for (int i = 0; i < _favoriteItems.length; i++) {
      final fav = _favoriteItems[i];
      final key = fav.isSeries ? '${fav.name}_' : '${fav.name}_${fav.url}';
      if (currentItemsMap.containsKey(key)) {
        _favoriteItems[i] = currentItemsMap[key]!.copyWith(isFavorite: true);
      }
    }

    // Add any new favorites found in M3U that aren't in _favoriteItems yet
    final Set<String> existingFavKeys = {
      for (var f in _favoriteItems)
        (f.isSeries ? '${f.name}_' : '${f.name}_${f.url}'),
    };

    for (var item in _items) {
      if (item.isFavorite) {
        final key =
            item.isSeries ? '${item.name}_' : '${item.name}_${item.url}';
        if (!existingFavKeys.contains(key)) {
          _favoriteItems.add(item);
          existingFavKeys.add(key);
        }
      }
    }

    // Save synced favorites back to disk
    _saveFavorites();

    // Guardar cache en background — no bloquea el main thread
    _saveJsonCache(output.items);

    // Diferir cálculo de recientes para no bloquear el frame inicial con isolate
    Future.delayed(const Duration(milliseconds: 50), () async {
      _cachedRecentItems = await compute(
        _computeRecentItemsInBackground,
        _items,
      );
      // Pre-warm popular search TMDB matches cache
      _fetchPopularFromTMDB();
      notifyListeners();
    });

    return true;
  }

  Future<void> _indexItems(
    List<M3UItem> items, {
    bool scheduleRecentCompute = true,
  }) async {
    _items = items;
    _cachedLatestItems = _calculateLatestItems(items).take(50).toList();
    _cachedRecentItems = null;

    try {
      final result = await compute(_indexItemsInBackground, {
        'items': items,
        'hasSagas': true, // Logic to include saga detection
      });

      _movies = (result['movies'] as List?)?.cast<M3UItem>() ?? [];
      _series = (result['series'] as List?)?.cast<M3UItem>() ?? [];
      _categoryIndex = Map<String, List<M3UItem>>.from(
        result['catIndex'] ?? {},
      );
      _urlIndex = Map<String, M3UItem>.from(result['urlIndex'] ?? {});
      _seriesNameIndex = Map<String, M3UItem>.from(
        result['seriesNameIndex'] ?? {},
      );
      _cachedCategories = List<String>.from(result['sortedCats']);

      notifyListeners();

      // FIX: Lanzar el cómputo asíncrono de items recientes también cuando
      // se carga desde caché. Antes solo ocurría en _processOutput() (descarga
      // fresca), lo que causaba que las secciones "Últimamente nuevo" y
      // "Recomendados para ti" no aparecieran al reiniciar la app.
      if (scheduleRecentCompute) {
        Future.delayed(const Duration(milliseconds: 100), () async {
          _cachedRecentItems = await compute(
            _computeRecentItemsInBackground,
            _items,
          );
          // También limpiar el caché de sesión de recomendaciones para que
          // se recalcule con los items frescos del caché.
          _sessionRecommendedItems = null;
          notifyListeners();
        });
      }
    } catch (e) {
      debugPrint('Error en la indexación local: $e');
    }
  }

  /// Fetches episodes for a series shell (specifically for Xtream Codes).
  Future<List<M3UItem>> fetchEpisodesForItem(M3UItem item) async {
    if (!item.isSeries) return [];
    if (item.episodes.isNotEmpty) return item.episodes;

    M3USource? source;
    try {
      if (item.sourceName != null) {
        source = _sources.firstWhere(
          (s) => s.name == item.sourceName,
          orElse: () => _sources[_activeSourceIndex],
        );
      } else {
        source = _sources[_activeSourceIndex];
      }
    } catch (_) {
      if (_sources.isNotEmpty) source = _sources[_activeSourceIndex];
    }

    if (source == null || source.type != 'xtream') return [];

    final xtream = XtreamService();
    final episodes = await xtream.fetchSeriesEpisodes(
      source.url,
      source.username ?? '',
      source.password ?? '',
      item.url, // series_id
      item.name,
    );

    // Dynamic indexing: add newly fetched episodes to the global URL index
    // so resolveItemFromProgress can find them immediately via URL.
    if (episodes.isNotEmpty) {
      for (final ep in episodes) {
        if (ep.url.isNotEmpty) {
          _urlIndex?[ep.url] = ep;
        }
      }
    }

    return episodes;
  }

  // ===========================================================================
  // QUERY HELPERS
  // ===========================================================================

  List<M3UItem> getItemsByCategory(String category) {
    if (category == 'Todos' || category == 'Inicio') return _items;
    return _categoryIndex?[category] ?? [];
  }

  M3UItem? getItemByUrl(String url) => _urlIndex?[url];

  M3UItem? getSeriesByName(String name) =>
      _seriesNameIndex?[NormalizationUtils.normalizeSeriesName(name)];

  /// Resolves an M3UItem from a WatchProgress entry using URL match or series fallback.
  /// Always attempts to return the "Series Shell" if the item is a series episode.
  M3UItem? resolveItemFromProgress(WatchProgress progress) {
    // 1. Direct URL match (Movies, Live, or M3U non-grouped items)
    final item = getItemByUrl(progress.url);
    if (item != null) {
      // If we found the specific episode, but it has a series name,
      // climb to the series shell for better UI grouping.
      if (item.seriesName != null && item.seriesName!.isNotEmpty) {
        final shell = getSeriesByName(item.seriesName!);
        if (shell != null) return shell;
      }
      return item;
    }

    // 2. Name-based resolution for series episodes (Xtream fallback)
    if (progress.seriesName != null && progress.seriesName!.isNotEmpty) {
      final shell = getSeriesByName(progress.seriesName!);
      if (shell != null) return shell;
    }

    return null;
  }

  /// Search items by name (synchronous for instant results).
  List<M3UItem> search(String query) {
    if (query.isEmpty) return _items;
    if (_items.isEmpty) return [];
    final q = query.toLowerCase();
    final results = <M3UItem>[];
    for (final item in _items) {
      if (item.name.toLowerCase().contains(q)) {
        results.add(item);
        if (results.length >= 100) break;
      }
    }
    return results;
  }

  /// Search for categories (collections/sagas) matching the query.
  List<String> searchCategories(String query) {
    if (query.isEmpty || _cachedCategories == null) return [];
    final queryLower = query.toLowerCase();
    final results =
        _cachedCategories!.where((cat) {
          return cat.toLowerCase().contains(queryLower);
        }).toList();
    results.sort((a, b) {
      final aIsColl = a.startsWith('Colección:');
      final bIsColl = b.startsWith('Colección:');
      if (aIsColl && !bIsColl) return -1;
      if (!aIsColl && bIsColl) return 1;
      return a.compareTo(b);
    });
    return results.take(5).toList();
  }

  List<M3UItem> getRecentItems() {
    // Si no está listo, devolver vacía en vez de calcular síncronamente
    // y congelar la pantalla. En 50ms se reconstruirá el UI (notifyListeners).
    return _cachedRecentItems ?? [];
  }

  List<M3UItem> getPopularSearchItems() {
    // If we already have TMDB matches, return them
    if (_cachedPopularTMDB != null && _cachedPopularTMDB!.isNotEmpty) {
      return _cachedPopularTMDB!;
    }

    // Trigger async fetch from TMDB if not already in progress
    if (_cachedPopularTMDB == null &&
        !_isFetchingPopularTMDB &&
        _items.isNotEmpty) {
      _fetchPopularFromTMDB();
    }

    // Si está en proceso de carga o no hay caché, devolvemos vacío para evitar parpadeo.
    // La UI mostrará un shimmer si está cargando.
    return [];
  }

  Future<void> _fetchPopularFromTMDB() async {
    if (_isFetchingPopularTMDB) return;
    _isFetchingPopularTMDB = true;

    try {
      final List<M3UItem> finalResults = [];
      final trends = await TMDBService().getTrendingTitles();

      if (trends.isNotEmpty) {
        final Set<String> matchedNames = {};
        for (var trend in trends) {
          final trendTitle = trend['title']?.toLowerCase() ?? '';
          final trendYear = trend['year'] ?? '';
          if (trendTitle.isEmpty) continue;

          // Fast search in local library
          for (var item in _items) {
            if (item.isLive || item.sourceName == 'Supabase') continue;
            if (matchedNames.contains(item.name)) continue;

            final itemName = item.name.toLowerCase();

            // Basic title match
            if (itemName.contains(trendTitle) ||
                trendTitle.contains(itemName)) {
              // Year verification for accuracy
              if (trendYear.isNotEmpty && item.name.contains(trendYear)) {
                finalResults.add(item);
                matchedNames.add(item.name);
                break;
              } else if (trendYear.isEmpty) {
                finalResults.add(item);
                matchedNames.add(item.name);
                break;
              }
            }
          }
          if (finalResults.length >= 9) break;
        }
      }

      // SMART FALLBACK: If no trends matched or matched nothing, pick recent/random items
      if (finalResults.isEmpty && _items.isNotEmpty) {
        final vods =
            _items
                .where((i) => !i.isLive && i.sourceName != 'Supabase')
                .toList();

        if (vods.isNotEmpty) {
          final regexYear = RegExp(r'\b(202[0-9]|19[0-9]{2})\b');
          int maxYear = 0;
          final Map<int, List<M3UItem>> yearGroups = {};

          for (var v in vods) {
            final match = regexYear.firstMatch(v.name);
            if (match != null) {
              final y = int.tryParse(match.group(1) ?? '0') ?? 0;
              if (y > 1900 && y < 2100) {
                if (y > maxYear) maxYear = y;
                yearGroups.putIfAbsent(y, () => []).add(v);
              }
            }
          }

          if (maxYear > 0) {
            // Content from the most recent year found
            final bestYearItems = yearGroups[maxYear]!;
            bestYearItems.shuffle();
            finalResults.addAll(bestYearItems.take(9));
          } else {
            // No years found, just random VODs (shuffled)
            vods.shuffle();
            finalResults.addAll(vods.take(9));
          }
        }
      }

      _cachedPopularTMDB = finalResults;
      if (finalResults.isNotEmpty) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error fetching TMDB popular trends: $e');
    } finally {
      _isFetchingPopularTMDB = false;
    }
  }

  /// PERF-4: getSimilarItems uses List.shuffle instead of random-attempt loop.
  ///
  /// The previous implementation looped up to 50 times with Random.nextInt,
  /// which could be slow and unpredictable. A single shuffle is O(n) deterministic.
  /// Smart similarity algorithm for the "Esto te puede gustar" section.
  ///
  /// Uses a scoring system based on:
  /// - Keyword overlap in titles (+10 per word)
  /// - Year proximity (+8 if same year, +4 if ±2 years)
  /// - Series matching (+25 if same seriesName)
  /// - Minimal randomization for variety
  List<M3UItem> getSimilarItems(M3UItem item) {
    // 1. BROAD DISCOVERY POOL: Combine movies and series (non-live)
    final allContent = [..._movies, ..._series];
    if (allContent.isEmpty) return [];

    final targetName = item.name.toLowerCase();
    final targetYear = _extractYearFromName(targetName);
    final targetKeywords = _extractKeywordsFromName(targetName);

    // 2. LIMIT CANDIDATE POOL: Sample up to 2000 items globally for performance
    // We mix some from the same category to ensure they appear even if title match is low.
    final sameCategory =
        allContent.where((i) => i.category == item.category).toList();
    final otherCategory =
        allContent.where((i) => i.category != item.category).toList();

    // Prioritize 200 from same category, fill rest (up to 1000 total) with others
    final pool = <M3UItem>[];
    pool.addAll(sameCategory.take(200));
    if (otherCategory.length > 800) {
      otherCategory.shuffle();
    }
    pool.addAll(otherCategory.take(800));

    // Filter out the current item
    final candidatesPool = pool.where((i) => i.url != item.url).toList();

    final scores = <String, int>{};
    final random = Random();

    for (var candidate in candidatesPool) {
      int score = 0;
      final candName = candidate.name.toLowerCase();

      // 1. Series Name Match (Strongest Signal)
      if (item.seriesName != null &&
          item.seriesName!.isNotEmpty &&
          candidate.seriesName == item.seriesName) {
        score += 35; // Increased boost for saga matching
      }

      // 2. Keyword Match
      final candKeywords = _extractKeywordsFromName(candName);
      final intersection = targetKeywords.intersection(candKeywords);
      score += intersection.length * 10;

      // 3. Same Category Bonus
      if (candidate.category == item.category) {
        score += 5; // Preference, but not a hard requirement
      }

      // 4. Year Proximity
      final candYear = _extractYearFromName(candName);
      if (targetYear != null && candYear != null) {
        if (targetYear == candYear) {
          score += 8;
        } else if ((targetYear - candYear).abs() <= 2) {
          score += 4;
        }
      }

      // 5. Randomized tie-breaker to keep it fresh
      score += random.nextInt(5);

      scores[candidate.url] = score;
    }

    // Sort by score descending
    candidatesPool.sort(
      (a, b) => (scores[b.url] ?? 0).compareTo(scores[a.url] ?? 0),
    );

    return candidatesPool.take(24).toList();
  }

  int? _extractYearFromName(String name) {
    final match = RegExp(r'\(?(\d{4})\)?').firstMatch(name);
    if (match != null) {
      final year = int.tryParse(match.group(1) ?? '');
      if (year != null && year > 1900 && year < 2110) return year;
    }
    return null;
  }

  Set<String> _extractKeywordsFromName(String name) {
    final stopWords = {
      'el',
      'la',
      'los',
      'las',
      'un',
      'una',
      'de',
      'del',
      'al',
      'lo',
      'y',
      'con',
      'en',
      'para',
      'the',
      'of',
      'and',
      'in',
      'movie',
      'pelicula',
      'series',
      'saga',
    };

    // Remove year, quality tags, and non-alphanumeric
    final cleaned =
        name
            .replaceAll(RegExp(r'\(?\d{4}\)?'), ' ')
            .replaceAll(
              RegExp(
                r'\b(hd|fhd|sd|4k|uhd|fullhd|dual|latino|castellano|sub|subtitulado|web|dl|bluray|x264|x265|aac)\b',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), ' ')
            .toLowerCase();

    return cleaned
        .split(' ')
        .where((s) => s.length > 2 && !stopWords.contains(s))
        .toSet();
  }

  /// Finds an alternative channel with a similar name in the same category.
  M3UItem? findMirrorChannel(M3UItem original) {
    if (original.alternatives.isNotEmpty) {
      for (var alt in original.alternatives) {
        if (alt.url != original.url) return alt;
      }
    }

    final categoryItems = getItemsByCategory(original.category);
    if (categoryItems.isEmpty) return null;

    String normalizeName(String name) {
      return name
          .toLowerCase()
          .replaceAll(RegExp(r'\b(hd|fhd|sd|4k|uhd|tv|vivo|en vivo)\b'), '')
          .replaceAll(RegExp(r'[^a-z0-9]'), '')
          .trim();
    }

    final normalizedOriginalName = normalizeName(original.name);
    if (normalizedOriginalName.isEmpty) return null;

    for (var item in categoryItems) {
      if (item.url == original.url) continue;
      final normalizedItemName = normalizeName(item.name);
      if (normalizedItemName == normalizedOriginalName) return item;
      if (normalizedOriginalName.length > 3 &&
          normalizedItemName.contains(normalizedOriginalName)) {
        return item;
      }
    }
    return null;
  }

  // ===========================================================================
  // RECOMMENDATIONS
  // ===========================================================================

  /// Limpia el caché de recomendaciones de sesión para forzar recompute
  /// en la próxima llamada a [getRecommendedItems].
  void clearSessionRecommendations() {
    _sessionRecommendedItems = null;
  }

  List<M3UItem> getRecommendedItems(List<dynamic> historyInput) {
    if (_items.isEmpty) return [];

    // Return session cache if available to keep recommendations stable
    if (_sessionRecommendedItems != null &&
        _sessionRecommendedItems!.isNotEmpty) {
      return _sessionRecommendedItems!;
    }

    final categoryScores = <String, int>{};
    final watchedSet = <String>{};
    final visitedSeries = <String>{};

    for (var url in _favorites) {
      final item = getItemByUrl(url);
      if (item != null) {
        categoryScores[item.category] =
            (categoryScores[item.category] ?? 0) + 5;
        if (item.seriesName != null) visitedSeries.add(item.seriesName!);
      }
      watchedSet.add(url);
    }

    int significantHistoryCount = 0;
    for (var entry in historyInput) {
      if (significantHistoryCount > 50) break;
      String url = '';
      bool isSignificant = true;

      if (entry is String) {
        url = entry;
      } else if (entry is Map) {
        url = entry['url']?.toString() ?? '';
        final progress =
            double.tryParse(entry['progressPercentage']?.toString() ?? '0') ??
            0.0;
        if (progress < 10) isSignificant = false;
      } else {
        try {
          url = (entry as dynamic).url;
          final double progress = (entry as dynamic).progressPercentage;
          if (progress < 10) isSignificant = false;
        } catch (_) {
          continue;
        }
      }

      if (url.isEmpty || !isSignificant) continue;

      // FIX: Use centralized resolution to handle Xtream series episodes
      final item = resolveItemFromProgress(
        entry is Map
            ? WatchProgress.fromJson(url, Map<String, dynamic>.from(entry))
            : (entry is WatchProgress
                ? entry
                : WatchProgress(
                  url: url,
                  positionSeconds: 0,
                  durationSeconds: 0,
                  timestamp: 0,
                )),
      );

      if (item != null) {
        watchedSet.add(url);
        significantHistoryCount++;
        if (item.seriesName != null) {
          if (visitedSeries.contains(item.seriesName)) continue;
          visitedSeries.add(item.seriesName!);
        }
        categoryScores[item.category] =
            (categoryScores[item.category] ?? 0) + 2;
      }
    }

    final sortedCategories =
        categoryScores.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));

    final topCategories =
        sortedCategories
            .take(3)
            .map((e) => e.key)
            .where((c) => c != 'Inicio' && c != 'Sin categoría')
            .toList();

    if (topCategories.isEmpty) {
      // FIX: Preferir categorías que tengan contenido no-live para evitar
      // que el fallback aleatorio elija solo categorías de TV en vivo,
      // lo que resultaría en candidates vacío y sección no visible.
      final nonLiveCategories =
          categories.where((c) {
            if (c == 'Inicio' || c == 'Sin categoría') return false;
            final catItems = _categoryIndex?[c];
            if (catItems == null || catItems.isEmpty) return false;
            return catItems.any((item) => !item.isLive);
          }).toList();

      if (nonLiveCategories.isNotEmpty) {
        nonLiveCategories.shuffle();
        topCategories.addAll(nonLiveCategories.take(3));
      } else {
        // Último recurso: categorías sin filtrar
        final validCategories =
            categories
                .where((c) => c != 'Inicio' && c != 'Sin categoría')
                .toList();
        validCategories.shuffle();
        topCategories.addAll(validCategories.take(3));
      }
    }

    final candidates = <M3UItem>[];
    for (var cat in topCategories) {
      final catItems = List<M3UItem>.from(getItemsByCategory(cat))..shuffle();
      for (var item in catItems.take(40)) {
        if (watchedSet.contains(item.url)) continue;
        if (item.isLive) continue;
        if (item.seriesName != null &&
            visitedSeries.contains(item.seriesName)) {
          continue;
        }
        candidates.add(item);
      }
    }

    // FIX: Si candidates sigue vacío (ej. todas las categorías eran live),
    // usar _movies y _series directamente como último recurso.
    if (candidates.isEmpty) {
      final allNonLive = <M3UItem>[..._movies, ..._series];
      allNonLive.shuffle();
      for (var item in allNonLive.take(60)) {
        if (watchedSet.contains(item.url)) continue;
        if (item.seriesName != null &&
            visitedSeries.contains(item.seriesName)) {
          continue;
        }
        candidates.add(item);
        if (candidates.length >= 15) break;
      }
    }

    candidates.shuffle();
    _sessionRecommendedItems = candidates.take(15).toList();
    return _sessionRecommendedItems!;
  }

  // ===========================================================================
  // SUPABASE ACTIONS
  // ===========================================================================

  /// Like content.
  ///
  /// FEAT-2: Deduplication — if the URL has already been liked in this
  /// installation, the Supabase insert is skipped silently.
  Future<bool> likeContent(M3UItem item) async {
    try {
      if (_supabase == null) return false;

      final identifier = item.url.isNotEmpty ? item.url : 'series_${item.name}';

      // FEAT-2: skip duplicate likes
      if (_likedUrls.contains(identifier)) return true;

      await _supabase!.from('content_likes').insert({
        'url': identifier,
        'name': item.name,
        'category': item.category,
      });

      _likedUrls.add(identifier);
      await _saveLikedUrls();
      return true;
    } catch (e) {
      debugPrint('likeContent error: $e');
      return false;
    }
  }

  Future<bool> reportContent({
    required String name,
    required String category,
    required String url,
    required String reason,
  }) async {
    try {
      if (_supabase == null) return false;
      await _supabase!.from('content_reports').insert({
        'content_name': name,
        'category': category,
        'url': url,
        'reason': reason,
        'device_id': _prefs?.getString('unique_device_id'),
      });
      return true;
    } catch (e) {
      debugPrint('Error reporting content: $e');
      return false;
    }
  }

  // ===========================================================================
  // FEAT-3: CONTENT STATS
  // ===========================================================================

  /// Returns aggregate statistics about the currently loaded content.
  ///
  /// FEAT-3: Useful for analytics screens, dashboards or debug panels.
  /// Example usage:
  ///   final stats = service.getContentStats();
  ///   print('${stats.totalItems} items across ${stats.totalCategories} categories');
  ContentStats getContentStats() {
    return ContentStats(
      totalItems: _items.length,
      totalMovies: _movies.length,
      totalSeries: _series.length,
      totalLive: _items.where((i) => i.isLive).length,
      totalCategories: _cachedCategories?.length ?? 0,
      totalFavorites: _favoriteItems.length,
      totalSagaCollections:
          (_cachedCategories ?? [])
              .where((c) => c.startsWith('Colección:'))
              .length,
      sourcesLoaded: _sources.length,
    );
  }

  // ===========================================================================
  // CACHE MANAGEMENT — ROBUST-3
  // ===========================================================================

  /// Checks if the main M3U cache has expired based on [_cacheDuration].
  bool _isCacheExpired() {
    final key = _isUnifiedMode ? _unifiedCacheTimestampKey : _cacheTimestampKey;
    final timestamp = _prefs?.getInt(key);
    if (timestamp == null) return true;

    final elapsed = DateTime.now().millisecondsSinceEpoch - timestamp;
    return elapsed > _cacheDuration.inMilliseconds;
  }

  /// Re-resolves all sources that were added via a code (like "1234").
  /// This ensures that the URL and credentials are up to date with the load balancer.
  Future<void> _reResolveCodesIfNeeded() async {
    if (_sources.isEmpty) return;

    bool changed = false;
    for (int i = 0; i < _sources.length; i++) {
      final source = _sources[i];
      if (source.isCode && source.originalInput != null) {
        try {
          final resolved = await resolveM3UInput(source.originalInput!);
          if (resolved.url != null) {
            // Check if anything meaningful changed (url, user, pass, or type)
            final bool urlChanged = resolved.url != source.url;
            final bool userChanged = resolved.username != source.username;
            final bool passChanged = resolved.password != source.password;
            final bool typeChanged = resolved.type != source.type;

            if (urlChanged || userChanged || passChanged || typeChanged) {
              debugPrint(
                'Re-resolved code ${source.originalInput}: updating source data.',
              );
              _sources[i] = M3USource(
                name: source.name,
                url: resolved.url!,
                isCode: true,
                originalInput: source.originalInput,
                username: resolved.username,
                password: resolved.password,
                type: resolved.type,
              );
              changed = true;
            }
          }
        } catch (e) {
          debugPrint('Error re-resolving code ${source.originalInput}: $e');
        }
      }
    }

    if (changed) {
      await _saveSources();
    }
  }

  /// ROBUST-3: clearCache now logs errors so failures are visible in debug builds.
  Future<void> clearCache() async {
    try {
      _items.clear();
      _movies.clear();
      _series.clear();
      _cachedCategories = null;
      _cachedLatestItems = null;
      _cachedRecentItems = null;
      _sessionRecommendedItems = null; // Reset recommendations on cache clear
      _categoryIndex = null;
      _urlIndex = null;

      final cacheFile = await _getCacheFile();
      if (await cacheFile.exists()) await cacheFile.delete();
      await _prefs?.remove(_cacheTimestampKey);

      await _prefs?.remove(_unifiedCacheTimestampKey);
      final directory = await getApplicationDocumentsDirectory();
      final dir = Directory(directory.path);

      await for (final entity in dir.list()) {
        if (entity is File &&
            (entity.path.contains(_unifiedCachePrefix) ||
                entity.path.contains('m3u_parsed_cache_'))) {
          try {
            await entity.delete();
          } catch (e) {
            debugPrint('clearCache: could not delete ${entity.path}: $e');
          }
        }
      }

      // Invalidate in-memory caches
      _items = [];
      _movies = [];
      _series = [];
      _cachedRecentItems = null;
      _cachedCategories = null;
      _categoryIndex = null;
      _urlIndex = null;
    } catch (e, stack) {
      // ROBUST-3: was swallowed before — now always visible in debug
      debugPrint('clearCache error: $e\n$stack');
    }
  }
}

@pragma('vm:entry-point')
String _encodeJsonCacheInBackground(Map<String, dynamic> data) {
  try {
    final items = data['items'] as List<M3UItem>;
    final secureKey = data['key'] as String;
    final jsonStr = json.encode(items.map((i) => i.toMap()).toList());

    // Manual XOR for isolate purity
    final bytes = utf8.encode(jsonStr);
    final keyBytes = utf8.encode(secureKey);
    final obfuscated = List<int>.generate(bytes.length, (i) {
      return bytes[i] ^ keyBytes[i % keyBytes.length];
    });
    return 'obf:${base64.encode(obfuscated)}';
  } catch (e) {
    return '';
  }
}

@pragma('vm:entry-point')
List<M3UItem> _decodeJsonCacheInBackground(Map<String, dynamic> data) {
  try {
    final String raw = data['raw'];
    final String secureKey = data['key'];

    if (!raw.startsWith('obf:')) return [];

    // Manual XOR for isolate purity
    final actualData = raw.substring(4);
    final bytes = base64.decode(actualData);
    final keyBytes = utf8.encode(secureKey);
    final decodedBytes = List<int>.generate(bytes.length, (i) {
      return bytes[i] ^ keyBytes[i % keyBytes.length];
    });
    final jsonStr = utf8.decode(decodedBytes);

    final List<dynamic> decoded = json.decode(jsonStr);
    return decoded
        .map((item) => M3UItem.fromMap(item as Map<String, dynamic>))
        .toList();
  } catch (e) {
    return [];
  }
}

@pragma('vm:entry-point')
List<M3UItem> _computeRecentItemsInBackground(List<M3UItem> items) {
  final regexYear = RegExp(r'\b(202[0-9]|19[0-9]{2})\b');
  final regexKeywords = RegExp(
    r'\b(estreno|cam|ts|screener|nuevo|new|2024|2025|2026)\b',
    caseSensitive: false,
  );

  int maxYear = 0;
  for (var item in items) {
    if (item.sourceName == 'Supabase') continue;
    final match = regexYear.firstMatch(item.name);
    if (match != null) {
      final year = int.tryParse(match.group(1) ?? '');
      if (year != null && year > maxYear && year < 2100) maxYear = year;
    }
  }

  final targetYears =
      maxYear > 0 ? [maxYear, maxYear - 1] : [DateTime.now().year];

  final recent =
      items.where((item) {
        if (item.isLive || item.sourceName == 'Supabase') return false;
        final match = regexYear.firstMatch(item.name);
        if (match != null) {
          final year = int.tryParse(match.group(1) ?? '');
          if (year != null && targetYears.contains(year)) return true;
        }
        if (regexKeywords.hasMatch(item.name) ||
            regexKeywords.hasMatch(item.category)) {
          return true;
        }
        return false;
      }).toList();

  recent.sort((a, b) {
    final yearA =
        int.tryParse(regexYear.firstMatch(a.name)?.group(1) ?? '0') ?? 0;
    final yearB =
        int.tryParse(regexYear.firstMatch(b.name)?.group(1) ?? '0') ?? 0;
    return yearB.compareTo(yearA);
  });

  return recent.take(60).toList();
}

// ===========================================================================
// MODELS & VALUE OBJECTS
// ===========================================================================

/// Aggregate statistics about loaded M3U content.
class ContentStats {
  final int totalItems;
  final int totalMovies;
  final int totalSeries;
  final int totalLive;
  final int totalCategories;
  final int totalFavorites;
  final int totalSagaCollections;
  final int sourcesLoaded;

  const ContentStats({
    required this.totalItems,
    required this.totalMovies,
    required this.totalSeries,
    required this.totalLive,
    required this.totalCategories,
    required this.totalFavorites,
    required this.totalSagaCollections,
    required this.sourcesLoaded,
  });

  @override
  String toString() =>
      'ContentStats(items: $totalItems, movies: $totalMovies, '
      'series: $totalSeries, live: $totalLive, '
      'categories: $totalCategories, sagas: $totalSagaCollections, '
      'favorites: $totalFavorites, sources: $sourcesLoaded)';
}

// ===========================================================================
// ISOLATE SUPPORT - VO & INPUTS
// ===========================================================================

class IsolateInput {
  final Uint8List contentBytes;
  final List<String> favorites;
  final List<Map<String, dynamic>> filters;
  final String? sourceName;
  IsolateInput(
    this.contentBytes,
    this.favorites,
    this.filters,
    this.sourceName,
  );
}

class IsolateOutput {
  final List<M3UItem> items;
  final List<M3UItem> movies;
  final List<M3UItem> series;
  final List<String> categories;
  final List<M3UItem> latestItems;
  final Map<String, List<M3UItem>> categoryIndex;
  final Map<String, M3UItem> urlIndex;
  final Map<String, M3UItem> seriesNameIndex;

  IsolateOutput({
    required this.items,
    required this.movies,
    required this.series,
    required this.categories,
    required this.latestItems,
    required this.categoryIndex,
    required this.urlIndex,
    required this.seriesNameIndex,
  });
}

@pragma('vm:entry-point')
IsolateOutput parseM3UInBackground(IsolateInput input) {
  final content = utf8.decode(input.contentBytes, allowMalformed: true);
  const int maxItems = 100000;
  final List<M3UItem> rawItems = [];
  final lines = content.split('\n');

  final filters =
      input.filters.map((f) {
        final pattern = (f['regex'] as String).replaceAll('(?i)', '');
        return {
          'category': f['category'] as String,
          'regex': RegExp(pattern, caseSensitive: false),
        };
      }).toList();

  // Pre-compile markers
  final bool hasFavorites = input.favorites.isNotEmpty;

  final logoRegex = RegExp(r'(?:tvg-logo|logo)="([^"]*)"');
  final categoryRegex = RegExp(r'group-title="([^"]*)"');

  // ── VOD signals ──────────────────────────────────────────────────────────
  final vodExtensionRegex = RegExp(
    r'\.(mp4|mkv|avi|mov|wmv|flv|webm|divx|xvid)(\?.*)?$',
    caseSensitive: false,
  );
  final vodCategoryRegex = RegExp(
    r'\b(peliculas|películas|movies?|series|serie|novelas?|documentales?|cine|vod|shows?|anime|infantil|kids|temporada|season|episodes?|capitulos?)\b',
    caseSensitive: false,
  );
  final vodYearRegex = RegExp(r'\(\d{4}\)');
  final vodEpisodeRegex = RegExp(
    r'\b(S\d{1,2}E\d{1,2}|\d{1,2}x\d{1,2}|T\d+\s*E\d+|Cap[íi]tulo\s*\d+|Ep(isodio)?\s*\d+)\b',
    caseSensitive: false,
  );

  // ── Live signals ─────────────────────────────────────────────────────────
  final liveProtocolRegex = RegExp(
    r'^rtmp[se]?://|^rtsp://',
    caseSensitive: false,
  );
  final liveTsRegex = RegExp(r'\.ts(\?.*)?$', caseSensitive: false);
  final liveCategoryTvSuffixRegex = RegExp(
    r'\bTV\s*\d*\s*$',
    caseSensitive: false,
  );
  final liveCategoryStrongRegex = RegExp(
    r'\b(canales?|live\s*tv|tv\s*en\s*vivo|noticias|en\s*emision|en\s*vivo|directo|señal\s*en\s*vivo'
    r'|ppv|eventos?\s*en\s*vivo|formula\s*1|gran\s*hermano|pass\s*tv'
    r'|24[/\\]7|kodimax|radio)\b',
    caseSensitive: false,
  );
  final liveCountryTvRegex = RegExp(
    r'\b(venezuela|colombia|argentina|mexico|méxico|chile|peru|perú|ecuador|bolivia'
    r'|uruguay|paraguay|panama|panamá|costa\s*rica|guatemala|honduras|nicaragua'
    r'|salvador|cuba|dominicana|puerto\s*rico|brasil|brazil|canada|españa|spain'
    r'|italia|arabia|usa|estados\s*unidos)\s*(tv)?\b',
    caseSensitive: false,
  );
  final liveSportsRegex = RegExp(
    r'\b(nfl|nba|mlb|nhl|ufc|mma|f1|motogp|laliga|champions|premier\s*league'
    r'|copa\s*america|mundial|olympics?|olimpicos?|boxeo|wrestling|lucha\s*libre)\b',
    caseSensitive: false,
  );
  final liveChannelNumberRegex = RegExp(
    r'\b(canal\s*\d+|\w+\s*\d+\s*(hd|fhd|sd|uhd|4k)?$|hd$|fhd$|uhd$|4k$)\b',
    caseSensitive: false,
  );
  final liveM3u8Regex = RegExp(r'\.m3u8(\?.*)?$', caseSensitive: false);
  final liveUrlPatternRegex = RegExp(
    r'/(live|stream|channel|canal|iptv|playlist|hls|ts|udp|rtp)/',
    caseSensitive: false,
  );

  final isAdultRegex = RegExp(
    r'\b(xxx|adulto|adultos|sensual|erotic|erotica|hot|porn|porno|pornografia|x-rated|onlyfans|playboy|brazzers|reality kings|naughty|hardcore|sex|sexo|hentai|milf|teen|lesbian|gay|amateur)\b|(\+18|18\+|\(\+18\)|\(18\+\)|\[\+18\]|\[18\+\])',
    caseSensitive: false,
  );

  for (int i = 0; i < lines.length && rawItems.length < maxItems; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTVLCOPT')) continue;

    if (line.startsWith('#EXTINF:')) {
      final logoMatch = logoRegex.firstMatch(line);
      final String? currentLogo = logoMatch?.group(1)?.trim();

      final categoryMatch = categoryRegex.firstMatch(line);
      String rawCategory = categoryMatch?.group(1) ?? 'Sin categoría';

      String currentCategory = NormalizationUtils.normalizeCategory(
        rawCategory,
      );

      final commaIndex = line.lastIndexOf(',');
      if (commaIndex == -1) continue;
      final String currentName = line.substring(commaIndex + 1).trim();
      if (currentName.isEmpty) continue;

      final nameLower = currentName.toLowerCase();
      final categoryLower = currentCategory.toLowerCase();

      if (isAdultRegex.hasMatch(categoryLower) ||
          isAdultRegex.hasMatch(nameLower)) {
        continue;
      }

      String? streamUrl;
      for (int j = i + 1; j < lines.length; j++) {
        final nextLine = lines[j].trim();
        if (nextLine.isEmpty) continue;
        if (nextLine.startsWith('#EXTINF:') || nextLine.startsWith('#EXTM3U')) {
          break;
        }
        if (nextLine.startsWith('#')) continue;
        streamUrl = nextLine;
        i = j;
        break;
      }

      if (streamUrl == null || streamUrl.isEmpty) continue;

      if (!streamUrl.startsWith('http://') &&
          !streamUrl.startsWith('https://') &&
          !streamUrl.startsWith('rtmp://') &&
          !streamUrl.startsWith('rtsp://')) {
        continue;
      }

      final urlLower = streamUrl.toLowerCase();

      bool shouldInclude = false;
      if (filters.isNotEmpty) {
        for (final filter in filters) {
          final regex = filter['regex'] as RegExp;
          if (regex.hasMatch(categoryLower) || regex.hasMatch(nameLower)) {
            shouldInclude = true;
            final targetCat = filter['category'] as String;
            if (targetCat != 'Sin categoría' && targetCat.isNotEmpty) {
              currentCategory = NormalizationUtils.normalizeCategory(targetCat);
            }
            break;
          }
        }
      }

      // ── Live vs VOD scoring ─────────────────────────────────────────────
      int liveScore = 0;
      if (vodExtensionRegex.hasMatch(urlLower)) liveScore -= 100;
      if (vodCategoryRegex.hasMatch(categoryLower)) liveScore -= 50;
      if (vodYearRegex.hasMatch(currentName)) liveScore -= 30;
      if (vodEpisodeRegex.hasMatch(currentName)) liveScore -= 40;
      if (liveProtocolRegex.hasMatch(urlLower)) liveScore += 80;
      if (liveTsRegex.hasMatch(urlLower)) liveScore += 50;
      if (liveCategoryTvSuffixRegex.hasMatch(currentCategory)) liveScore += 60;
      if (liveCategoryStrongRegex.hasMatch(categoryLower)) liveScore += 50;
      if (liveCountryTvRegex.hasMatch(categoryLower)) liveScore += 35;
      if (liveSportsRegex.hasMatch(categoryLower) ||
          liveSportsRegex.hasMatch(nameLower)) {
        liveScore += 45;
      }
      if (liveChannelNumberRegex.hasMatch(nameLower)) liveScore += 20;
      if (liveM3u8Regex.hasMatch(urlLower)) liveScore += 20;
      if (liveUrlPatternRegex.hasMatch(urlLower)) liveScore += 25;

      final bool isLive = liveScore > 0;

      if (!shouldInclude) {
        shouldInclude = true;
        if (isLive &&
            (currentCategory == 'Sin categoría' ||
                currentCategory == 'SIN CATEGORÍA')) {
          currentCategory = 'Canales en Vivo';
        }
      }

      // Logo filtering removed to allow TMDB fallback to work for all items

      if (shouldInclude) {
        final isFav =
            hasFavorites &&
            input.favorites.contains('${currentName}_$streamUrl');
        rawItems.add(
          M3UItem(
            name: currentName,
            url: streamUrl,
            logo: currentLogo,
            category: currentCategory,
            isFavorite: isFav,
            isLive: isLive,
            sourceName: input.sourceName,
          ),
        );
      }
    }
  }

  // ── Unify categories ───────────────────────────────────────────────────
  // Pass 2: Map all items to canonical category names based on normalized keys
  final Map<String, String> canonicalNames = {};
  for (final item in rawItems) {
    final key = _normalizeCategoryKey(item.category);
    if (!canonicalNames.containsKey(key) ||
        _isBetterCategoryName(canonicalNames[key]!, item.category)) {
      canonicalNames[key] = item.category;
    }
  }

  for (int j = 0; j < rawItems.length; j++) {
    final key = _normalizeCategoryKey(rawItems[j].category);
    if (canonicalNames.containsKey(key) &&
        rawItems[j].category != canonicalNames[key]) {
      rawItems[j] = rawItems[j].copyWith(category: canonicalNames[key]);
    }
  }

  final groupedAlternatives = _groupAlternatives(rawItems);
  final groupedItems = _groupSeries(groupedAlternatives, input.favorites);
  final sortedGrouped = _calculateLatestItems(groupedItems);

  final movies = sortedGrouped.where((i) => !i.isSeries && !i.isLive).toList();
  final series = sortedGrouped.where((i) => i.isSeries && !i.isLive).toList();

  final Map<String, List<M3UItem>> catIndex = {};
  final Set<String> catSet = {};
  final Map<String, M3UItem> urlIndex = {};
  final Map<String, M3UItem> seriesNameIndex = {};

  for (final item in sortedGrouped) {
    catIndex.putIfAbsent(item.category, () => []).add(item);
    catSet.add(item.category);
    if (item.url.isNotEmpty) urlIndex[item.url] = item;

    if (item.isSeries) {
      seriesNameIndex[item.name.trim().toLowerCase()] = item;
    }
    for (final ep in item.episodes) {
      if (ep.url.isNotEmpty) urlIndex[ep.url] = ep;
      for (final alt in ep.alternatives) {
        if (alt.url.isNotEmpty) urlIndex[alt.url] = ep;
      }
    }
    for (final alt in item.alternatives) {
      if (alt.url.isNotEmpty) urlIndex[alt.url] = item;
    }
  }

  final categories = _sortCategoriesByPriority(catSet);
  _addSagaCategories(movies, catIndex, categories);

  return IsolateOutput(
    items: sortedGrouped,
    movies: movies,
    series: series,
    categories: categories,
    latestItems: sortedGrouped.take(50).toList(),
    categoryIndex: catIndex,
    urlIndex: urlIndex,
    seriesNameIndex: seriesNameIndex,
  );
}

// ===========================================================================
// CATEGORY PRIORITY SORT
// ===========================================================================

const List<String> _categoryPriorityPatterns = [
  'ultimamente',
  'ultimo',
  'reciente',
  'nuevo',
  'estreno',
  'estrenos',
  'novedad',
  'cam',
  'netflix',
  'disney',
  'hbo',
  'amazon',
  'prime',
  'apple',
  'appletv',
  'paramount',
  'hulu',
  'peacock',
  'star',
  'crunchyroll',
  'accion',
  'acción',
  'action',
  'aventura',
  'adventure',
  'animado',
  'animados',
  'animacion',
  'animación',
  'animation',
  'anime',
  'ciencia ficcion',
  'ciencia ficción',
  'sci-fi',
  'scifi',
  'fantasia',
  'fantasía',
  'fantasy',
  'comedia',
  'comedy',
  'humor',
  'drama',
  'thriller',
  'suspenso',
  'suspense',
  'terror',
  'horror',
  'misterio',
  'mystery',
  'infantil',
  'kids',
  'familia',
  'family',
  'pixar',
  'romance',
  'romantica',
  'romántica',
  'western',
  'historica',
  'histórica',
  'guerra',
  'war',
  'biopic',
  'biografia',
  'documental',
  'documentary',
  'deportes',
  'sport',
  'crimen',
  'crime',
  'policial',
  'latino',
  'latina',
  'hispano',
  'espanol',
  'español',
  'mexico',
  'colombia',
  'argentina',
  'serie',
  'series',
  'temporada',
  'season',
  'novela',
  'telenovela',
  'dorama',
  'turca',
  'turco',
  'telemundo',
  'televisa',
];

const List<String> _categoryLowPriorityPatterns = [
  'religion',
  'religión',
  'musica',
  'música',
  'music',
  'radio',
  'noticias',
  'news',
  'deportivo',
  'variedad',
  'entretenimiento',
];

int _getItemQualityScore(String name) {
  final n = name.toLowerCase();
  int score = 50;

  if (n.contains('4k') || n.contains('uhd')) score += 50;
  if (n.contains('1080') || n.contains('fhd') || n.contains('bluray')) {
    score += 40;
  }
  if (n.contains('720') || n.contains(' hd')) score += 30;

  if (n.contains('cam') ||
      n.contains('ts') ||
      n.contains('telesync') ||
      n.contains('hd-ts') ||
      n.contains('line') ||
      n.contains('tc') ||
      n.contains('scr')) {
    score -= 80;
  }

  if (n.contains('opc') ||
      n.contains('opcion') ||
      n.contains('opo ') ||
      n.contains('op ') ||
      n.contains('server')) {
    score -= 5;
  }

  return score;
}

int _getCategoryPriority(String category) {
  final catLower = category.toLowerCase();
  for (int i = 0; i < _categoryPriorityPatterns.length; i++) {
    if (catLower.contains(_categoryPriorityPatterns[i])) return i;
  }
  for (final lp in _categoryLowPriorityPatterns) {
    if (catLower.contains(lp)) return 9000;
  }
  if (catLower.startsWith('colección:')) return 10000;
  return 500;
}

List<String> _sortCategoriesByPriority(Set<String> catSet) {
  final cats = catSet.where((c) => c != 'Inicio').toList();
  cats.sort((a, b) {
    final pa = _getCategoryPriority(a);
    final pb = _getCategoryPriority(b);
    if (pa != pb) return pa.compareTo(pb);
    return a.compareTo(b);
  });
  if (catSet.contains('Inicio')) cats.insert(0, 'Inicio');
  return cats;
}

List<M3UItem> _calculateLatestItems(List<M3UItem> items) {
  final now = DateTime.now();
  final currentYear = now.year;
  final previousYear = currentYear - 1;
  final Map<M3UItem, double> itemScores = {};
  final regexYear = RegExp(r'\b(202[0-9]|19[0-9]{2})\b');

  for (var item in items) {
    // STRICT FILTER: No live streams or Supabase content in "latest" calculations
    if (item.isLive || item.sourceName == 'Supabase') {
      itemScores[item] = -1000.0;
      continue;
    }

    double score = 0;
    final match = regexYear.firstMatch(item.name);
    if (match != null) {
      final yearStr = match.group(1) ?? '';
      final year = int.tryParse(yearStr);
      if (year != null) {
        if (year == currentYear) {
          score += 2000; // Increased priority for current year
        } else if (year == previousYear) {
          score += 1000;
        } else {
          score += (year - 1900);
        }
      }
    }

    final n = item.name.toLowerCase();
    if (n.contains('nuevo') ||
        n.contains('reciente') ||
        n.contains('estreno')) {
      score += 500;
    }
    if (item.isFavorite) score += 100;
    itemScores[item] = score;
  }

  return items.toList()
    ..sort((a, b) => itemScores[b]!.compareTo(itemScores[a]!));
}

// ===========================================================================
// SERIES GROUPING
// ===========================================================================

List<M3UItem> _groupSeries(List<M3UItem> flatItems, List<String> favorites) {
  if (flatItems.isEmpty) return [];

  final Map<String, List<M3UItem>> seriesMap = {};
  final List<M3UItem> standaloneItems = [];

  final regexSxxEx = RegExp(
    r'^(.*?)\s*S(\d+)[._ -]*E(\d+)',
    caseSensitive: false,
  );
  final regexNxN = RegExp(r'^(.*?)\s*(\d+)x(\d+)', caseSensitive: false);
  final regexTrim = RegExp(r'[-_.]+$');

  String capSignature(String name) {
    final cleaned =
        name
            .replaceAll(RegExp(r'S\d+E\d+.*', caseSensitive: false), '')
            .replaceAll(RegExp(r'\d+x\d+.*', caseSensitive: false), '')
            .trim();
    if (cleaned.isEmpty) return 'mixed';
    final lettersOnly = cleaned.replaceAll(
      RegExp(r'[^a-zA-ZáéíóúÁÉÍÓÚñÑ]'),
      '',
    );
    if (lettersOnly.isEmpty) return 'mixed';

    final upperCount =
        lettersOnly.runes.where((r) {
          final ch = String.fromCharCode(r);
          return ch == ch.toUpperCase() && ch != ch.toLowerCase();
        }).length;
    final lowerCount =
        lettersOnly.runes.where((r) {
          final ch = String.fromCharCode(r);
          return ch == ch.toLowerCase() && ch != ch.toUpperCase();
        }).length;
    final total = upperCount + lowerCount;
    if (total == 0) return 'mixed';

    final upperRatio = upperCount / total;
    if (upperRatio >= 0.85) return 'upper';
    if (upperRatio <= 0.15) return 'lower';

    final words = cleaned.trim().split(RegExp(r'\s+'));
    if (words.isEmpty) return 'mixed';
    final titleWords =
        words.where((w) {
          if (w.isEmpty) return false;
          final first = w[0];
          return first == first.toUpperCase() && first != first.toLowerCase();
        }).length;
    if (titleWords / words.length >= 0.7) return 'title';
    return 'mixed';
  }

  // Replaced local normalizeSeriesName with central NormalizationUtils.normalizeSeriesName

  for (final item in flatItems) {
    final catLower = item.category.toLowerCase();
    if (catLower.contains('movie') ||
        catLower.contains('pelicula') ||
        catLower.contains('cine') ||
        catLower.contains('vod movies')) {
      standaloneItems.add(item);
      continue;
    }

    String? seriesName;
    int? seasonNum;
    int? episodeNum;

    final match1 = regexSxxEx.firstMatch(item.name);
    if (match1 != null) {
      seriesName = match1.group(1)?.trim();
      seasonNum = int.tryParse(match1.group(2) ?? '');
      episodeNum = int.tryParse(match1.group(3) ?? '');
    } else {
      final match2 = regexNxN.firstMatch(item.name);
      if (match2 != null) {
        seriesName = match2.group(1)?.trim();
        seasonNum = int.tryParse(match2.group(2) ?? '');
        episodeNum = int.tryParse(match2.group(3) ?? '');
      }
    }

    if (seriesName != null && seriesName.isNotEmpty) {
      final sanitizedName = seriesName.replaceAll(regexTrim, '').trim();
      final normalizedPart = NormalizationUtils.normalizeSeriesName(
        sanitizedName,
      );
      final capSig = capSignature(sanitizedName);
      final groupKey = '${normalizedPart}_$capSig';

      seriesMap
          .putIfAbsent(groupKey, () => [])
          .add(
            item.copyWith(
              seriesName: sanitizedName,
              seasonNumber: seasonNum,
              episodeNumber: episodeNum,
            ),
          );
    } else {
      standaloneItems.add(item);
    }
  }

  final List<M3UItem> result = [...standaloneItems];
  seriesMap.forEach((key, eps) {
    eps.sort(
      (a, b) =>
          (b.seriesName ?? '').length.compareTo((a.seriesName ?? '').length),
    );
    final displayName = eps.first.seriesName!;
    eps.sort((a, b) {
      if (a.seasonNumber != b.seasonNumber) {
        return (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
      }
      return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
    });
    final isFav = favorites.contains('${displayName}_');
    result.add(
      M3UItem(
        name: displayName,
        url: '',
        logo: eps.first.logo,
        category: eps.first.category,
        episodes: eps,
        seriesName: displayName,
        isFavorite: isFav,
        sourceName: eps.first.sourceName,
      ),
    );
  });

  return result;
}

// ===========================================================================
// ALTERNATIVES GROUPING
// ===========================================================================

List<M3UItem> _groupAlternatives(List<M3UItem> flatItems) {
  if (flatItems.isEmpty) return [];

  final Map<String, M3UItem> map = {};
  final Map<String, String> urlToKey = {};

  for (final item in flatItems) {
    String key;
    final bool isVod = !item.isLive;

    if (item.isLive) {
      key =
          'live_${item.name.trim().toLowerCase()}_${item.category.trim().toLowerCase()}';
    } else {
      String n = _removeAccents(item.name.toLowerCase());
      // 1. Remove everything in parentheses and brackets (e.g. (CAM), [HD])
      n = n.replaceAll(RegExp(r'\(.*?\)'), ' ');
      n = n.replaceAll(RegExp(r'\[.*?\]'), ' ');
      // 2. Remove common quality/language keywords and mirror indicators
      n = n.replaceAll(
        RegExp(
          r'\b(4k|uhd|hd|fhd|sd|multi|latino|castellano|sub|subtitulado|dual|cam|ts|tc|hd-ts|telesync|scr|opc?\s*\d+|opcion\s*\d+|opo\s*\d+|server\s*\d+|dual|lat|spa|esp|eng|vo|vose|h264|h265|x264|x265|avc|hevc|web-dl|webrip|bluray|brrip|dvdrip|telesync|scr)\b',
        ),
        ' ',
      );
      // 3. Remove non-alphanumeric characters
      final normalizedName = n.replaceAll(RegExp(r'[^a-z0-9]'), '').trim();
      key = 'vod_$normalizedName';
      if (normalizedName.isEmpty) key = 'vod_raw_${item.name.toLowerCase()}';
    }

    if (isVod && item.url.isNotEmpty && urlToKey.containsKey(item.url)) {
      key = urlToKey[item.url]!;
    }

    if (map.containsKey(key)) {
      final existing = map[key]!;
      if (existing.url != item.url &&
          !existing.alternatives.any((alt) => alt.url == item.url)) {
        final existingScore = _getItemQualityScore(existing.name);
        final currentScore = _getItemQualityScore(item.name);

        const genericCats = [
          'Inicio',
          'Recientes',
          'Recently Added',
          'Estrenos',
        ];

        final bool itemIsSpecificCat =
            !genericCats.any((c) => item.category.contains(c));
        final bool existingIsSpecificCat =
            !genericCats.any((c) => existing.category.contains(c));

        // Logic for swapping:
        // 1. If current item has strictly better quality, swap.
        // 2. If quality is equal and current has a more specific category, swap.
        bool shouldSwap = currentScore > existingScore;
        if (currentScore == existingScore &&
            itemIsSpecificCat &&
            !existingIsSpecificCat) {
          shouldSwap = true;
        }

        final bool newIsFavorite = existing.isFavorite || item.isFavorite;

        if (shouldSwap) {
          map[key] = item.copyWith(
            isFavorite: newIsFavorite,
            alternatives: [existing, ...existing.alternatives],
          );
        } else {
          map[key] = existing.copyWith(
            isFavorite: newIsFavorite,
            alternatives: [item, ...existing.alternatives],
          );
        }
      }
    } else {
      map[key] = item;
      if (isVod && item.url.isNotEmpty) urlToKey[item.url] = key;
    }
  }

  return map.values.toList();
}

// ===========================================================================
// SAGA / COLLECTION DETECTION
// ===========================================================================

final _reYear = RegExp(r'\s*[\(\[]?\d{4}[\)\]]?\s*');
final _reQuality = RegExp(
  r'\b(4k|uhd|hd|fhd|sd|bluray|blu-ray|dvdrip|hdtv|web-dl|webrip|cam|ts|remux|extended|theatrical|remastered)\b',
  caseSensitive: false,
);
final _rePart = RegExp(
  r'\b(parte|part|vol|volume|volumen|chapter|capitulo|cap|ep|episodio)\s*[0-9ivxlcdm]+\b',
  caseSensitive: false,
);
final _rePartWord = RegExp(
  r'\b(parte|part)\s+(uno|dos|tres|cuatro|one|two|three|four)\b',
  caseSensitive: false,
);
final _reSpaces = RegExp(r'\s+');
final _reConj = RegExp(
  r'\s+('
  r'y\s+el\s+|y\s+la\s+|y\s+lo\s+|y\s+los\s+|y\s+las\s+'
  r'|y\s+un\s+|y\s+una\s+'
  r'|e\s+los\s+|e\s+las\s+'
  r'|and\s+the\s+|and\s+a\s+|and\s+an\s+'
  r'|of\s+the\s+|of\s+a\s+'
  r'|de\s+la\s+|de\s+los\s+|de\s+las\s+|del\s+'
  r'|en\s+el\s+|en\s+la\s+|en\s+los\s+'
  r'|con\s+el\s+|con\s+la\s+'
  r')',
  caseSensitive: false,
);
final _reDash = RegExp(r'\s+[-–—]\s+');
final _reTrailingRoman = RegExp(r'\s+[ivxlcdm]+$', caseSensitive: false);
final _reTrailingNum = RegExp(r'\s+\d+$');
final _reLeadingArticle = RegExp(
  r'^(the|el|la|los|las|un|una)\s+',
  caseSensitive: false,
);
final _reNonAlphaSpace = RegExp(r'[^a-z0-9\s]');

String _removeAccents(String input) {
  const withAcc = 'áàäâãåæÁÀÄÂÃÅÆéèëêÉÈËÊíìïîÍÌÏÎóòöôõøÓÒÖÔÕØúùüûÚÙÜÛýÝñÑçÇ';
  const noAcc = 'aaaaaaaaaaaaaaeeeeeeeeiiiiiiiiooooooooooooouuuuuuuuyynncc';
  final buf = StringBuffer();
  for (int i = 0; i < input.length; i++) {
    final idx = withAcc.indexOf(input[i]);
    buf.write(idx >= 0 ? noAcc[idx] : input[i]);
  }
  return buf.toString();
}

String _normalizeCategoryKey(String category) {
  String normalized = _removeAccents(category.toLowerCase().trim());

  // 1. Remove everything in parentheses and brackets (e.g. (CAM), [HD])
  normalized = normalized.replaceAll(RegExp(r'\(.*?\)'), ' ');
  normalized = normalized.replaceAll(RegExp(r'\[.*?\]'), ' ');

  // 1.1 Remove "cam" regardless if it's in parentheses or not (e.g. "Estrenos Cam")
  normalized = normalized.replaceAll(
    RegExp(
      r'\b(cam|ts|tc|hd|4k|uhd|fhd|sd|dual|multi|latino|sub|subtitulado|line|scr)\b',
      caseSensitive: false,
    ),
    ' ',
  );

  normalized = normalized.trim();

  // Predefined unifications for common bilingual or typo issues
  if (normalized == 'action') normalized = 'accion';
  if (normalized == 'adventure') normalized = 'aventura';
  if (normalized == 'movies') normalized = 'peliculas';
  if (normalized == 'estrenos' ||
      normalized == 'estreno' ||
      normalized == 'estrenos cam' ||
      normalized == 'estreno cam') {
    normalized = 'estrenos';
  }
  if (normalized == 'series') {
    normalized = 'serie'; // unify plural/singular for series
  }

  // Basic plural removal for general categories (e.g. Aventuras -> Aventura, Peliculas -> Pelicula)
  if (normalized.endsWith('s') &&
      normalized.length > 5 &&
      !['noticias', 'deportes', 'kids', 'estrenos'].contains(normalized)) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

/// Determines if candidate is a "better" (more complete/properly accented) name for the same category.
bool _isBetterCategoryName(String current, String candidate) {
  if (current == candidate) return false;

  // 1. PENALIZAR NOMBRES CON PARÉNTESIS O CORCHETES (ej. "Estrenos (Cam)")
  // Queremos el nombre más limpio posible como base.
  final bool currentHasExtra =
      current.contains('(') ||
      current.contains('[') ||
      current.toLowerCase().contains(' cam');
  final bool candidateHasExtra =
      candidate.contains('(') ||
      candidate.contains('[') ||
      candidate.toLowerCase().contains(' cam');

  if (!currentHasExtra && candidateHasExtra) {
    return false; // El actual ya es limpio
  }
  if (currentHasExtra && !candidateHasExtra) {
    return true; // El candidato es más limpio
  }

  // 2. Preferir nombres con acentos
  int currentAccents = current.length - _removeAccents(current).length;
  int candidateAccents = candidate.length - _removeAccents(candidate).length;

  if (candidateAccents > currentAccents) return true;
  if (candidateAccents < currentAccents) return false;

  // If accents are equal, prefer the one with more capital letters (as a proxy for proper Title Case)
  int currentCaps = current.runes.where((r) => r >= 65 && r <= 90).length;
  int candidateCaps = candidate.runes.where((r) => r >= 65 && r <= 90).length;

  return candidateCaps > currentCaps;
}

String _extractFranchiseKey(String rawName) {
  String name = _removeAccents(rawName.toLowerCase().trim());
  name = name.replaceAll(_reYear, ' ');
  name = name.replaceAll(_reQuality, '');
  name = name.replaceAll(_rePart, '');
  name = name.replaceAll(_rePartWord, '');
  name = name.replaceAll(_reSpaces, ' ').trim();

  final colonIdx = name.indexOf(':');
  if (colonIdx > 3) {
    final c = name.substring(0, colonIdx).trim();
    if (c.length >= 3) name = c;
  }

  final conjMatch = _reConj.firstMatch(name);
  if (conjMatch != null && conjMatch.start > 4) {
    final c = name.substring(0, conjMatch.start).trim();
    if (c.length >= 3) name = c;
  }

  final dashMatch = _reDash.firstMatch(name);
  if (dashMatch != null && dashMatch.start > 4) {
    final c = name.substring(0, dashMatch.start).trim();
    if (c.length >= 4) name = c;
  }

  name = name.replaceAll(_reTrailingRoman, '');
  name = name.replaceAll(_reTrailingNum, '');
  String key = name.replaceAll(_reLeadingArticle, '');
  key = key.replaceAll(_reNonAlphaSpace, ' ');
  key = key.replaceAll(_reSpaces, ' ').trim();
  return key;
}

Map<String, List<M3UItem>> _fuzzyMergeGroups(
  Map<String, List<M3UItem>> groups,
) {
  final candidateKeys =
      groups.keys.where((k) => groups[k]!.length >= 2).toList();
  if (candidateKeys.length <= 1) return groups;

  final Map<String, String> mergeMap = {};
  final Map<String, Set<String>> wordSets = {};
  for (final k in candidateKeys) {
    wordSets[k] = k.split(' ').toSet();
  }

  for (int i = 0; i < candidateKeys.length; i++) {
    final ka = candidateKeys[i];
    if (mergeMap.containsKey(ka)) continue;
    for (int j = i + 1; j < candidateKeys.length; j++) {
      final kb = candidateKeys[j];
      if (mergeMap.containsKey(kb)) continue;
      final wordsA = wordSets[ka]!;
      final wordsB = wordSets[kb]!;
      final aInB = wordsA.every((w) => wordsB.contains(w));
      final bInA = wordsB.every((w) => wordsA.contains(w));
      if (aInB || bInA) {
        if (ka.length <= kb.length) {
          mergeMap[ka] = kb;
        } else {
          mergeMap[kb] = ka;
        }
        continue;
      }
      final intersection = wordsA.intersection(wordsB);
      final union = wordsA.union(wordsB);
      if (union.isNotEmpty && intersection.length / union.length >= 0.6) {
        if (ka.length >= kb.length) {
          mergeMap[kb] = ka;
        } else {
          mergeMap[ka] = kb;
        }
      }
    }
  }

  if (mergeMap.isEmpty) return groups;

  String resolve(String k) {
    final visited = <String>{};
    while (mergeMap.containsKey(k) && !visited.contains(k)) {
      visited.add(k);
      k = mergeMap[k]!;
    }
    return k;
  }

  final Map<String, List<M3UItem>> result = {};
  for (final entry in groups.entries) {
    final canonical = resolve(entry.key);
    result.putIfAbsent(canonical, () => []).addAll(entry.value);
  }
  return result;
}

void _addSagaCategories(
  List<M3UItem> movies,
  Map<String, List<M3UItem>> catIndex,
  List<String> categories,
) {
  if (movies.isEmpty) return;

  final Map<String, List<M3UItem>> rawGroups = {};
  for (final movie in movies) {
    final key = _extractFranchiseKey(movie.name);
    if (key.length < 3) continue;
    rawGroups.putIfAbsent(key, () => []).add(movie);
  }

  final mergedGroups = _fuzzyMergeGroups(rawGroups);
  final regexYear = RegExp(r'\((\d{4})\)');

  mergedGroups.forEach((key, items) {
    if (items.length < 3) return;

    final seenUrls = <String>{};
    final uniqueItems = <M3UItem>[];
    for (final item in items) {
      if (item.url.isEmpty || !seenUrls.contains(item.url)) {
        seenUrls.add(item.url);
        uniqueItems.add(item);
      }
    }
    if (uniqueItems.length < 3) return;

    final String title = key
        .split(' ')
        .map(
          (w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '',
        )
        .join(' ');
    final String catName = 'Colección: $title';

    uniqueItems.sort((a, b) {
      final ya =
          int.tryParse(regexYear.firstMatch(a.name)?.group(1) ?? '0') ?? 0;
      final yb =
          int.tryParse(regexYear.firstMatch(b.name)?.group(1) ?? '0') ?? 0;
      return ya.compareTo(yb);
    });

    catIndex[catName] = uniqueItems;
    if (!categories.contains(catName)) categories.add(catName);
  });
}

@pragma('vm:entry-point')
Map<String, dynamic> _indexItemsInBackground(Map<String, dynamic> input) {
  final List<M3UItem> items = List<M3UItem>.from(input['items']);
  final bool hasSagas = input['hasSagas'] ?? true;

  final Map<String, List<M3UItem>> catIndex = {};
  final Set<String> catSet = {};
  final Map<String, M3UItem> urlIndex = {};
  final Map<String, M3UItem> seriesNameIndex = {};
  final List<M3UItem> movies = [];
  final List<M3UItem> series = [];

  for (final item in items) {
    // Index by category
    catIndex.putIfAbsent(item.category, () => []).add(item);
    catSet.add(item.category);

    // Individual item maps for search/lookup
    if (item.url.isNotEmpty) urlIndex[item.url] = item;

    // Deep indexing for series episodes and alternatives
    for (final ep in item.episodes) {
      if (ep.url.isNotEmpty) urlIndex[ep.url] = ep;
      for (final alt in ep.alternatives) {
        if (alt.url.isNotEmpty) urlIndex[alt.url] = ep;
      }
    }
    for (final alt in item.alternatives) {
      if (alt.url.isNotEmpty) urlIndex[alt.url] = item;
    }

    // Categorize by type
    if (!item.isLive) {
      if (item.isSeries) {
        series.add(item);
        seriesNameIndex[NormalizationUtils.normalizeSeriesName(item.name)] =
            item;
      } else {
        movies.add(item);
      }
    }
  }

  final sortedCats = _sortCategoriesByPriority(catSet);
  if (hasSagas) {
    _addSagaCategories(movies, catIndex, sortedCats);
  }

  return {
    'movies': movies,
    'series': series,
    'catIndex': catIndex,
    'urlIndex': urlIndex,
    'seriesNameIndex': seriesNameIndex,
    'sortedCats': sortedCats,
  };
}
