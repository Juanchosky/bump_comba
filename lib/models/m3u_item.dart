import '../utils/normalization_utils.dart';

/// Model for an M3U channel/movie
class M3UItem {
  final String name;
  final String url;
  final String? logo;
  final String category;
  bool isFavorite;
  final String? duration;

  // Series support
  final List<M3UItem> episodes;
  final String? seriesName;
  final int? seasonNumber;
  final int? episodeNumber;
  final bool isLive;
  final bool isDynamic;

  // Alternatives support
  final List<M3UItem> alternatives;
  final String? sourceName;

  final bool? _isSeries;
  bool? get explicitIsSeries => _isSeries;
  bool get isSeries => _isSeries ?? episodes.isNotEmpty;
  bool get hasAlternatives => alternatives.isNotEmpty;

  /// Normalized identity used to deduplicate the same title that may be stored
  /// under different URLs (e.g. played from distinct sources or with a refreshed
  /// token). For series we key by the series name so all episodes collapse into
  /// one; for movies we key by the display name with the year suffix stripped.
  String get contentKey {
    final base =
        (seriesName != null && seriesName!.isNotEmpty) ? seriesName! : name;
    return base
        .toLowerCase()
        .replaceAll(RegExp(r'\s*\(\d{4}\)'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  M3UItem({
    required this.name,
    required this.url,
    this.logo,
    required this.category,
    this.isFavorite = false,
    this.episodes = const [],
    this.seriesName,
    this.seasonNumber,
    this.episodeNumber,
    bool? isSeries,
    this.isLive = false,
    this.isDynamic = false,
    this.alternatives = const [],
    this.sourceName,
    this.duration,
  }) : _isSeries = isSeries;

  M3UItem copyWith({
    String? name,
    String? url,
    String? logo,
    String? category,
    bool? isFavorite,
    List<M3UItem>? episodes,
    String? seriesName,
    int? seasonNumber,
    int? episodeNumber,
    bool? isSeries,
    bool? isLive,
    bool? isDynamic,
    List<M3UItem>? alternatives,
    String? sourceName,
  }) {
    return M3UItem(
      name: name ?? this.name,
      url: url ?? this.url,
      logo: logo ?? this.logo,
      category: category ?? this.category,
      isFavorite: isFavorite ?? this.isFavorite,
      episodes: episodes ?? this.episodes,
      seriesName: seriesName ?? this.seriesName,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      isSeries: isSeries ?? _isSeries,
      isLive: isLive ?? this.isLive,
      isDynamic: isDynamic ?? this.isDynamic,
      alternatives: alternatives ?? this.alternatives,
      sourceName: sourceName ?? this.sourceName,
      duration: duration ?? duration,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'n': name,
      'u': url,
      'l': logo,
      'c': category,
      'f': isFavorite ? 1 : 0,
      'e': episodes.map((e) => e.toMap()).toList(),
      'sn': seriesName,
      's': seasonNumber,
      'ep': episodeNumber,
      'is': _isSeries == true ? 1 : 0,
      'lv': isLive ? 1 : 0,
      'dy': isDynamic ? 1 : 0,
      'a': alternatives.map((a) => a.toMap()).toList(),
      'src': sourceName,
      'dur': duration,
    };
  }

  factory M3UItem.fromMap(Map<String, dynamic> map) {
    return M3UItem(
      name: map['n'] ?? '',
      url: map['u'] ?? '',
      logo: map['l'],
      category:
          map['c'] != null && (map['c'] as String).isNotEmpty
              ? NormalizationUtils.normalizeCategory(map['c'] as String)
              : 'Sin categoría',
      isFavorite: map['f'] == 1,
      episodes:
          (map['e'] as List? ?? []).map((e) => M3UItem.fromMap(e)).toList(),
      seriesName: map['sn'],
      seasonNumber: map['s'],
      episodeNumber: map['ep'],
      isSeries: map['is'] == null ? null : (map['is'] == 1),
      isLive: map['lv'] == 1,
      isDynamic: map['dy'] == 1,
      alternatives:
          (map['a'] as List? ?? []).map((a) => M3UItem.fromMap(a)).toList(),
      sourceName: map['src'],
      duration: map['dur'],
    );
  }
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is M3UItem &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          url == other.url;

  @override
  int get hashCode => name.hashCode ^ url.hashCode;
}

/// Model for remote filter rules
class FilterRule {
  final String category;
  final String regexPattern;
  final int priority;

  FilterRule({
    required this.category,
    required this.regexPattern,
    this.priority = 0,
  });

  factory FilterRule.fromJson(Map<String, dynamic> json) => FilterRule(
    category: json['category'] ?? '',
    regexPattern: json['regex_pattern'] ?? '',
    priority: json['priority'] ?? 0,
  );
}

/// Model for cloud-based IPTV sources
class CloudSource {
  final String id;
  final String name;
  final String url;
  final DateTime? visibleUntil;

  CloudSource({
    required this.id,
    required this.name,
    required this.url,
    this.visibleUntil,
  });

  factory CloudSource.fromJson(Map<String, dynamic> json) => CloudSource(
    id: json['id']?.toString() ?? '',
    name: json['name'] ?? '',
    url: json['url'] ?? '',
    visibleUntil:
        json['visible_until'] != null
            ? DateTime.tryParse(json['visible_until'])
            : null,
  );
}
