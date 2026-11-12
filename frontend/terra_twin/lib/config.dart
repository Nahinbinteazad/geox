// lib/config.dart
//
// Single place for every backend address the frontend uses.
// Override any value at run time without editing this file:
//   flutter run -d chrome --dart-define=GEOX_API_URL=http://localhost:8000
//
// SAFE to keep here: the project URL and the *publishable* key (sb_publishable_...).
// NEVER put these in the app: the secret key (sb_secret_...), the service_role
// key, or the JWT secret. Those belong only on the backend server.
class AppConfig {
  /// Supabase project URL.
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://xrxajakukyhhsaifhqmu.supabase.co',
  );

  /// Supabase publishable key (the modern replacement for the "anon" key).
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_sC-nfInHXqER6wn0lH-e4A_0Q01gyuT',
  );

  /// GeoX FastAPI backend (open target scoring, suggested sites, shortlists).
  /// Empty until the backend is running or deployed.
  static const apiUrl = String.fromEnvironment(
    'GEOX_API_URL',
    defaultValue: '',
  );
}