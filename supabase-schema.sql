-- Shared quote-call calendar and settings.
-- Anonymous access is intentionally enabled at the user's request. It is not
-- limited to people who know the Netlify URL; protect customer details accordingly.

create table if not exists public.quote_appointments (
  id uuid primary key default gen_random_uuid(),
  location text not null check (location in ('Victoria', 'Prince George')),
  appointment_date date not null,
  appointment_time time,
  client_name text not null default '',
  address text not null default '',
  notes text not null default '',
  salesperson text not null default '',
  property_count integer not null default 1 check (property_count between 1 and 20),
  is_blocked boolean not null default false,
  is_all_day_block boolean not null default false,
  created_by uuid default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  check (not is_all_day_block or (is_blocked and appointment_time is null))
);

alter table public.quote_appointments add column if not exists property_count integer not null default 1 check (property_count between 1 and 20);
alter table public.quote_appointments add column if not exists is_blocked boolean not null default false;
alter table public.quote_appointments add column if not exists is_all_day_block boolean not null default false;
alter table public.quote_appointments alter column created_by drop not null;
alter table public.quote_appointments alter column client_name set default '';

create unique index if not exists quote_appointments_unique_slot
on public.quote_appointments (location, appointment_date, appointment_time)
where appointment_time is not null;

alter table public.quote_appointments enable row level security;
grant select, insert, update, delete on public.quote_appointments to anon, authenticated;

do $$ begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'quote_appointments'
      and policyname = 'Public no-login access to booked quote calls'
  ) then
    create policy "Public no-login access to booked quote calls"
    on public.quote_appointments for all to anon using (true) with check (true);
  end if;
end $$;

create table if not exists public.quote_settings (
  id boolean primary key default true check (id),
  slot_minutes integer not null default 20 check (slot_minutes in (20, 30, 60)),
  salespeople text[] not null default array['Josh', 'Joyce', 'Setter', 'Online']::text[],
  workday_start time not null default '09:00',
  workday_end time not null default '16:00',
  updated_at timestamptz not null default now()
);
alter table public.quote_settings add column if not exists workday_start time not null default '09:00';
alter table public.quote_settings add column if not exists workday_end time not null default '16:00';
insert into public.quote_settings (id) values (true) on conflict (id) do nothing;

alter table public.quote_settings enable row level security;
grant select, insert, update, delete on public.quote_settings to anon, authenticated;
do $$ begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'quote_settings'
      and policyname = 'Public no-login access to quote settings'
  ) then
    create policy "Public no-login access to quote settings"
    on public.quote_settings for all to anon using (true) with check (true);
  end if;
end $$;

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='quote_appointments') then
      alter publication supabase_realtime add table public.quote_appointments;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='quote_settings') then
      alter publication supabase_realtime add table public.quote_settings;
    end if;
  end if;
end $$;
