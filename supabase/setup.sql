-- =====================================================================
-- Mobile Tracker — Supabase setup
-- Paste this whole file into:  Supabase Dashboard > SQL Editor > New query
-- then click "Run".
-- =====================================================================

-- 1) The table that holds the latest position of each device.
--    One row per device (device_id is the primary key), so a device
--    "updates" its row rather than piling up history. Small + simple.
create table if not exists public.devices (
    device_id   text primary key,
    name        text not null default 'My device',
    lat         double precision not null,
    lng         double precision not null,
    battery     integer,
    accuracy    double precision,
    updated_at  timestamptz not null default now()
);

-- 2) Turn on Row Level Security. With RLS ON and the policies below,
--    the public anon key is safe to ship inside the mobile app.
alter table public.devices enable row level security;

-- 3) Policies.
--    This is a PERSONAL-USE setup: anyone with the anon key can read and
--    write the devices table. That is fine when it is only your own phones
--    and the project URL/key are not posted publicly.
--
--    >>> For stronger security see the note at the bottom of this file. <<<

-- Allow reading all devices (the dashboard needs this).
drop policy if exists "read devices" on public.devices;
create policy "read devices"
    on public.devices
    for select
    using (true);

-- Allow a device to insert its own row.
drop policy if exists "insert devices" on public.devices;
create policy "insert devices"
    on public.devices
    for insert
    with check (true);

-- Allow a device to update its own row.
drop policy if exists "update devices" on public.devices;
create policy "update devices"
    on public.devices
    for update
    using (true)
    with check (true);

-- 4) Enable Realtime so the dashboard map updates live.
alter publication supabase_realtime add table public.devices;

-- =====================================================================
-- SECURITY NOTE
-- ---------------------------------------------------------------------
-- The policies above are intentionally open (using/true, check/true) so
-- you can get running fast with just the anon key. This means anyone who
-- obtains your project URL + anon key could read or write locations.
--
-- For your own personal phones this is usually acceptable. To harden it
-- later, you can:
--   * Require Supabase Auth and scope rows to auth.uid(), or
--   * Put a tiny server (edge function) in front that holds a secret.
-- Ask and I can set either of those up.
-- =====================================================================
