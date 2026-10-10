// ============================================================
//  Supabase project values.
//  Supabase Dashboard > Connect (or Project Settings > API Keys)
//    - Project URL        -> SUPABASE_URL
//    - Publishable key     -> SUPABASE_ANON_KEY
//
//  NOTE: This project uses the newer "publishable" key format
//  (sb_publishable_...). It is the drop-in replacement for the old
//  anon key and is safe in client code while RLS is enabled.
// ============================================================
window.APP_CONFIG = {
  SUPABASE_URL: "https://oyxennrwhltlhugnegun.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_1uIwf3z3h1CwdaW-sXQl1A_K3cneAIE",

  // MapTiler key for the detailed, Google-like map styles.
  // MapTiler Cloud > API Keys. Safe to expose in client code (it's a
  // public map key). Restrict it to your domain later in MapTiler if you like.
  MAPTILER_KEY: "gqz3V2e5GO51SIJfqYBz",
  SUPER_ADMIN_PIN: "admin123", // Master PIN to access Admin Portal and manage all companies
};
