// ============================================================
//  Supabase project values.
//  Supabase Dashboard > Connect (or Project Settings > API Keys)
//    - Project URL     -> supabaseUrl
//    - Publishable key -> supabaseAnonKey
//
//  NOTE: This project uses the newer "publishable" key format
//  (sb_publishable_...). It is the drop-in replacement for the old
//  anon key and is safe in client code while RLS is enabled.
// ============================================================
class AppConfig {
  static const String supabaseUrl = "https://oyxennrwhltlhugnegun.supabase.co";
  static const String supabaseAnonKey =
      "sb_publishable_1uIwf3z3h1CwdaW-sXQl1A_K3cneAIE";

  // How often to report location, in seconds.
  // Larger = better battery life. 120s (2 min) is a good balance.
  static const int reportIntervalSeconds = 120;

  // Only send a new point if the phone moved at least this many meters.
  // Saves battery and network when the phone is sitting still.
  static const int minDistanceMeters = 25;
}
