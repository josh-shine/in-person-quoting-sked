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

-- Signed-in admins and users should see the same shared bookings as anon.
-- The anon policy above already makes this data public; this policy prevents
-- RLS from filtering every row after a user signs in.
do $$ begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'quote_appointments'
      and policyname = 'Authenticated access to booked quote calls'
  ) then
    create policy "Authenticated access to booked quote calls"
    on public.quote_appointments for all to authenticated using (true) with check (true);
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

-- Email-based app roles. Booking rows stay shared with anon as requested.
-- Keep the owner email in this private table, not in the public app source.
create table if not exists public.app_access_config (
  id boolean primary key default true check (id),
  owner_email text not null check (owner_email = lower(owner_email)),
  updated_at timestamptz not null default now()
);
alter table public.app_access_config enable row level security;
revoke all on public.app_access_config from anon, authenticated, public;

-- Only the owner account can assign or change roles. Other signed-in users
-- default to the User role unless an Admin role is assigned here.
create table if not exists public.app_user_roles (
  email text primary key check (email = lower(email)),
  role text not null default 'user' check (role in ('admin', 'user')),
  updated_at timestamptz not null default now()
);

alter table public.app_user_roles enable row level security;
revoke all on public.app_user_roles from anon, public;
grant select, insert, update, delete on public.app_user_roles to authenticated;

create or replace function public.is_quote_app_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = (
    select owner_email from public.app_access_config where id = true
  );
$$;

create or replace function public.get_quote_app_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when public.is_quote_app_owner() then 'owner'
    else coalesce((
      select role from public.app_user_roles
      where email = lower(coalesce(auth.jwt() ->> 'email', ''))
    ), 'user')
  end;
$$;

revoke all on function public.is_quote_app_owner() from public, anon;
grant execute on function public.is_quote_app_owner() to authenticated;
revoke all on function public.get_quote_app_role() from public, anon;
grant execute on function public.get_quote_app_role() to authenticated;

drop policy if exists "Users can read own app role" on public.app_user_roles;
create policy "Users can read own app role"
on public.app_user_roles for select to authenticated
using (email = lower(coalesce(auth.jwt() ->> 'email', '')));

drop policy if exists "Owner can manage app roles" on public.app_user_roles;
create policy "Owner can manage app roles"
on public.app_user_roles for all to authenticated
using (public.is_quote_app_owner())
with check (public.is_quote_app_owner());

insert into public.app_user_roles (email, role)
select owner_email, 'admin' from public.app_access_config where id = true
on conflict (email) do update
set role = 'admin', updated_at = now();
