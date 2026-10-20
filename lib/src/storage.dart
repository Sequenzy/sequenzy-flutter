import 'package:shared_preferences/shared_preferences.dart';

/// Persistent string storage for identity, the event queue and push state.
abstract class SequenzyStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String? value);
}

class MemoryStore implements SequenzyStore {
  MemoryStore([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

/// SharedPreferences with every key prefixed by `sequenzy.`.
class SharedPreferencesStore implements SequenzyStore {
  SharedPreferencesStore({this.prefix = 'sequenzy.'});

  final String prefix;
  SharedPreferences? _preferences;

  Future<SharedPreferences> get _instance async => _preferences ??= await SharedPreferences.getInstance();

  @override
  Future<String?> getString(String key) async => (await _instance).getString(prefix + key);

  @override
  Future<void> setString(String key, String? value) async {
    final preferences = await _instance;
    if (value == null) {
      await preferences.remove(prefix + key);
    } else {
      await preferences.setString(prefix + key, value);
    }
  }
}
