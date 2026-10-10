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
  // 10s gives real-time Swiggy/Zomato style live movement!
  static const int reportIntervalSeconds = 10;

  // Only send a new point if the phone moved at least this many meters.
  // 10m allows fluid street-level updates.
  static const int minDistanceMeters = 10;

  // Default company code for multi-tenancy.
  static const String defaultCompanyCode = 'DEFAULT';
}
