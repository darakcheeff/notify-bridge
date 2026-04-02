import 'package:shared_preferences/shared_preferences.dart';

class FilteringEngine {
  List<String> whitelist = [];
  List<String> blacklist = [];
  List<String> allowedApps = [];

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    whitelist = prefs.getStringList('whitelist') ?? [];
    blacklist = prefs.getStringList('blacklist') ?? [];
    allowedApps = prefs.getStringList('allowed_apps') ?? [];
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('whitelist', whitelist);
    await prefs.setStringList('blacklist', blacklist);
    await prefs.setStringList('allowed_apps', allowedApps);
  }

  bool shouldSend(String appPackage, String title, String body) {
    final content = (title + " " + body).toLowerCase();

    // Priority 1: Whitelist (Override)
    for (final word in whitelist) {
      if (word.trim().isNotEmpty && content.contains(word.trim().toLowerCase())) {
        return true;
      }
    }

    // Priority 2: App Filter (If not in allowed apps list, ignore)
    if (!allowedApps.contains(appPackage)) return false;

    // Priority 3: Blacklist (If contains blacklisted word, ignore)
    for (final word in blacklist) {
      if (word.trim().isNotEmpty && content.contains(word.trim().toLowerCase())) {
        return false;
      }
    }

    // Default: Send
    return true;
  }
}
