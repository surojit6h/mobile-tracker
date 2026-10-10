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
    speed       double precision,          -- km/h from GPS (nullable)
    distance    double precision,          -- km from phone trip meter (nullable)
    heading     double precision,          -- bearing/rotation in degrees 0-360 (nullable)
    phone       text,                      -- device mobile/phone number (nullable)
    company_code text not null default 'DEFAULT', -- tenant code for multi-tenancy
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

-- Allow deleting a device row (needed by the dashboard "Delete device" button).
drop policy if exists "delete devices" on public.devices;
create policy "delete devices"
    on public.devices
    for delete
    using (true);

-- 4) Enable Realtime so the dashboard map updates live.
--    Guarded so re-running this file does not error if the table was
--    already added to the publication on a previous run.
do $$
begin
  alter publication supabase_realtime add table public.devices;
exception
  when duplicate_object then null;  -- already a member, ignore
end $$;

-- =====================================================================
-- 5) Location HISTORY table — one row per report (never overwritten).
--    This is what lets the dashboard draw a travel path / trail.
--    The `devices` table above keeps only the latest point; this table
--    keeps every point so we can connect them into a line.
-- =====================================================================
create table if not exists public.locations (
    id          bigint generated always as identity primary key,
    device_id   text not null,
    lat         double precision not null,
    lng         double precision not null,
    battery     integer,
    accuracy    double precision,
    speed       double precision,          -- km/h from GPS (nullable)
    distance    double precision,          -- km from phone trip meter (nullable)
    heading     double precision,          -- bearing/rotation in degrees 0-360 (nullable)
    recorded_at timestamptz not null default now()
);

-- Fast lookups of "this device's points, newest first".
create index if not exists locations_device_time_idx
    on public.locations (device_id, recorded_at desc);

alter table public.locations enable row level security;

-- Same personal-use policies as `devices`: open read + insert.
drop policy if exists "read locations" on public.locations;
create policy "read locations"
    on public.locations
    for select
    using (true);

drop policy if exists "insert locations" on public.locations;
create policy "insert locations"
    on public.locations
    for insert
    with check (true);

-- Allow deleting history (needed by the dashboard's "Clear history" button
-- and the auto-cleanup). Personal-use: open, same as the other policies.
drop policy if exists "delete locations" on public.locations;
create policy "delete locations"
    on public.locations
    for delete
    using (true);

-- (Optional) stream history inserts live to the dashboard too.
--    Guarded so re-running this file is safe.
do $$
begin
  alter publication supabase_realtime add table public.locations;
exception
  when duplicate_object then null;  -- already a member, ignore
end $$;

-- =====================================================================
-- 6) Auto-cleanup of old history so the table never grows unbounded.
--    Uses pg_cron (built into Supabase) to delete rows older than
--    30 days, once a day at 03:30 UTC. Change the interval or schedule
--    below to taste. Safe to re-run: the schedule is replaced each time.
-- =====================================================================

-- pg_cron ships with Supabase but must be enabled once.
create extension if not exists pg_cron;

-- A small function that trims history older than the retention window.
-- Keeping the window in one place makes it easy to change later.
create or replace function public.cleanup_old_locations()
returns void
language sql
as $$
    delete from public.locations
    where recorded_at < now() - interval '30 days';
$$;

-- (Re)schedule the daily cleanup. Unschedule any existing job with the
-- same name first so re-running this file doesn't create duplicates.
do $$
begin
  perform cron.unschedule('cleanup-old-locations');
exception
  when others then null;  -- no existing job, ignore
end $$;

select cron.schedule(
    'cleanup-old-locations',           -- job name
    '30 3 * * *',                      -- every day at 03:30 UTC
    $$ select public.cleanup_old_locations(); $$
);

-- =====================================================================
-- 7) Migration: add the `speed` column to existing installations.
--    Safe to re-run on a brand-new project too (IF NOT EXISTS guard).
-- =====================================================================
alter table if exists public.devices
    add column if not exists speed double precision;   -- km/h, nullable

alter table if exists public.locations
    add column if not exists speed double precision;   -- km/h, nullable

-- =====================================================================
-- 8) Migration: add the `distance` column (trip km) so the dashboard
--    matches the phone app's trip meter exactly.
-- =====================================================================
alter table if exists public.devices
    add column if not exists distance double precision;   -- km, nullable

alter table if exists public.locations
    add column if not exists distance double precision;   -- km, nullable

-- =====================================================================
-- 9) Migration: add `heading` column (bearing angle in degrees 0-360)
--    for Swiggy/Zomato style vehicle rotation.
-- =====================================================================
alter table if exists public.devices
    add column if not exists heading double precision;   -- degrees 0-360, nullable

alter table if exists public.locations
    add column if not exists heading double precision;   -- degrees 0-360, nullable

-- =====================================================================
-- 10) Migration: add `phone` column for mobile number.
-- =====================================================================
alter table if exists public.devices
    add column if not exists phone text;

-- =====================================================================
-- 11) Multi-Tenancy: Companies / Tenants table & device association
-- =====================================================================
create table if not exists public.companies (
    id          text primary key,
    code        text not null unique,
    name        text not null,
    admin_pin   text not null default '1234',
    created_at  timestamptz not null default now()
);

alter table public.companies enable row level security;

drop policy if exists "read companies" on public.companies;
create policy "read companies" on public.companies for select using (true);

drop policy if exists "insert companies" on public.companies;
create policy "insert companies" on public.companies for insert with check (true);

drop policy if exists "update companies" on public.companies;
create policy "update companies" on public.companies for update using (true) with check (true);

drop policy if exists "delete companies" on public.companies;
create policy "delete companies" on public.companies for delete using (true);

do $$
begin
  alter publication supabase_realtime add table public.companies;
exception
  when duplicate_object then null;
end $$;

-- Insert default company so existing devices work automatically
insert into public.companies (id, code, name, admin_pin)
values ('comp_default', 'DEFAULT', 'Main Fleet', '1234')
on conflict (code) do nothing;

-- Add company_code to devices and locations
alter table if exists public.devices
    add column if not exists company_code text not null default 'DEFAULT';

alter table if exists public.locations
    add column if not exists company_code text not null default 'DEFAULT';

create index if not exists devices_company_code_idx on public.devices (company_code);
create index if not exists locations_company_code_idx on public.locations (company_code);

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
