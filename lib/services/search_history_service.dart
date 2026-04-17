import 'package:shared_preferences/shared_preferences.dart';

/// Service to manage search history with local persistence
class SearchHistoryService {
  static final SearchHistoryService _instance =
      SearchHistoryService._internal();
  factory SearchHistoryService() => _instance;
  SearchHistoryService._internal();

  static const String _searchHistoryKey = 'search_history';
  static const int _maxHistorySize = 10;

  SharedPreferences? _prefs;

  /// Initialize the service
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  /// Get the list of recent searches
  Future<List<String>> getSearchHistory() async {
    await _ensureInitialized();
    final history = _prefs!.getStringList(_searchHistoryKey) ?? [];
    return history;
  }

  /// Add a search query to history
  /// - Ignores empty strings
  /// - Moves existing query to top if already present
  /// - Limits to max history size
  Future<void> addSearch(String query) async {
    await _ensureInitialized();

    // Ignore empty or whitespace-only queries
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) return;

    List<String> history = await getSearchHistory();

    // Remove existing occurrence if present (to avoid duplicates)
    history.remove(trimmedQuery);

    // Add to the beginning (most recent first)
    history.insert(0, trimmedQuery);

    // Limit to max size
    if (history.length > _maxHistorySize) {
      history = history.sublist(0, _maxHistorySize);
    }

    await _prefs!.setStringList(_searchHistoryKey, history);
  }

  /// Remove a specific search query from history
  Future<void> removeSearch(String query) async {
    await _ensureInitialized();

    List<String> history = await getSearchHistory();
    history.remove(query);

    await _prefs!.setStringList(_searchHistoryKey, history);
  }

  /// Clear all search history
  Future<void> clearHistory() async {
    await _ensureInitialized();
    await _prefs!.remove(_searchHistoryKey);
  }

  /// Ensure SharedPreferences is initialized
  Future<void> _ensureInitialized() async {
    _prefs ??= await SharedPreferences.getInstance();
  }
}
