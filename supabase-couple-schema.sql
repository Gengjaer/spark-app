-- Lulu Life couple space schema.
-- Run this once in Supabase SQL Editor.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  nickname text not null default '我',
  last_seen_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.couples (
  id uuid primary key default gen_random_uuid(),
  name text not null default '我们的噜噜窝',
  invite_code text not null unique,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.couple_members (
  couple_id uuid not null references public.couples(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member',
  joined_at timestamptz not null default now(),
  primary key (couple_id, user_id)
);

create table if not exists public.shared_todos (
  id text primary key,
  couple_id uuid not null references public.couples(id) on delete cascade,
  text text not null,
  due_date date not null default current_date,
  done boolean not null default false,
  completed_at timestamptz,
  created_by uuid not null references auth.users(id) on delete cascade,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.period_records (
  id text primary key,
  couple_id uuid not null references public.couples(id) on delete cascade,
  start_date date not null,
  end_date date,
  daily_logs jsonb not null default '{}'::jsonb,
  created_by uuid not null references auth.users(id) on delete cascade,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.couple_plan_items (
  id text primary key,
  couple_id uuid not null references public.couples(id) on delete cascade,
  category text not null default 'other',
  title text not null,
  note text not null default '',
  target_date date,
  done boolean not null default false,
  created_by uuid not null references auth.users(id) on delete cascade,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

alter table public.couple_plan_items
add column if not exists target_date date;

create table if not exists public.couple_notes (
  id text primary key,
  couple_id uuid not null references public.couples(id) on delete cascade,
  body text not null,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create or replace function public.is_couple_member(target_couple_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.couple_members
    where couple_id = target_couple_id
      and user_id = auth.uid()
  );
$$;

create or replace function public.create_couple_space(p_name text, p_invite_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_couple_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if exists (select 1 from public.couple_members where user_id = auth.uid()) then
    raise exception 'already in a couple space';
  end if;

  insert into public.couples (name, invite_code, created_by)
  values (coalesce(nullif(trim(p_name), ''), '我们的噜噜窝'), upper(trim(p_invite_code)), auth.uid())
  returning id into new_couple_id;

  insert into public.couple_members (couple_id, user_id, role)
  values (new_couple_id, auth.uid(), 'owner');

  return new_couple_id;
end;
$$;

create or replace function public.join_couple_by_invite(p_invite_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target_couple_id uuid;
  member_count int;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if exists (select 1 from public.couple_members where user_id = auth.uid()) then
    raise exception 'already in a couple space';
  end if;

  select id into target_couple_id
  from public.couples
  where invite_code = upper(trim(p_invite_code));

  if target_couple_id is null then
    raise exception 'invite code not found';
  end if;

  select count(*) into member_count
  from public.couple_members
  where couple_id = target_couple_id;

  if member_count >= 2 then
    raise exception 'couple space is full';
  end if;

  insert into public.couple_members (couple_id, user_id, role)
  values (target_couple_id, auth.uid(), 'member');

  return target_couple_id;
end;
$$;

alter table public.profiles enable row level security;
alter table public.couples enable row level security;
alter table public.couple_members enable row level security;
alter table public.shared_todos enable row level security;
alter table public.period_records enable row level security;
alter table public.couple_plan_items enable row level security;
alter table public.couple_notes enable row level security;

grant usage on schema public to anon, authenticated;
grant select, insert, update on all tables in schema public to authenticated;
grant execute on function public.create_couple_space(text, text) to authenticated;
grant execute on function public.join_couple_by_invite(text) to authenticated;

drop policy if exists "profiles_select_related" on public.profiles;
create policy "profiles_select_related"
on public.profiles
for select
to authenticated
using (
  id = auth.uid()
  or exists (
    select 1
    from public.couple_members mine
    join public.couple_members other on other.couple_id = mine.couple_id
    where mine.user_id = auth.uid()
      and other.user_id = profiles.id
  )
);

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own"
on public.profiles
for insert
to authenticated
with check (id = auth.uid());

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
on public.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists "couples_select_member" on public.couples;
create policy "couples_select_member"
on public.couples
for select
to authenticated
using (public.is_couple_member(id));

drop policy if exists "members_select_member" on public.couple_members;
create policy "members_select_member"
on public.couple_members
for select
to authenticated
using (public.is_couple_member(couple_id));

drop policy if exists "shared_todos_member_all" on public.shared_todos;
create policy "shared_todos_member_all"
on public.shared_todos
for all
to authenticated
using (public.is_couple_member(couple_id))
with check (public.is_couple_member(couple_id));

drop policy if exists "period_records_member_all" on public.period_records;
create policy "period_records_member_all"
on public.period_records
for all
to authenticated
using (public.is_couple_member(couple_id))
with check (public.is_couple_member(couple_id));

drop policy if exists "plan_items_member_all" on public.couple_plan_items;
create policy "plan_items_member_all"
on public.couple_plan_items
for all
to authenticated
using (public.is_couple_member(couple_id))
with check (public.is_couple_member(couple_id));

drop policy if exists "couple_notes_member_all" on public.couple_notes;
create policy "couple_notes_member_all"
on public.couple_notes
for all
to authenticated
using (public.is_couple_member(couple_id))
with check (public.is_couple_member(couple_id));
