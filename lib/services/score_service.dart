import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing game scores and high scores
class ScoreService {
  static const String _highScoreKey = 'high_score';

  SharedPreferences? _prefs;
  int _highScore = 0;

  int get highScore => _highScore;

  /// Initialize the service
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _highScore = _prefs?.getInt(_highScoreKey) ?? 0;
  }

  /// Check if score is a new high score and save it
  Future<bool> checkAndSaveHighScore(int score) async {
    if (score > _highScore) {
      _highScore = score;
      await _prefs?.setInt(_highScoreKey, score);
      return true;
    }
    return false;
  }

  /// Reset high score (for testing)
  Future<void> resetHighScore() async {
    _highScore = 0;
    await _prefs?.setInt(_highScoreKey, 0);
  }
}
