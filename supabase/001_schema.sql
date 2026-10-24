-- Run once in the Supabase SQL Editor of a new project, as postgres.
-- Browser clients only have access to the two authorized RPCs at the end.
begin;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table private.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
create table private.members (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 60),
  email text unique check (email is null or email = lower(btrim(email))),
  active boolean not null default true,
  rating double precision not null default 1000,
  wins integer not null default 0,
  losses integer not null default 0,
  delta double precision not null default 0
);
create sequence private.confirmation_order;
create table private.matches (
  id uuid primary key,
  winner uuid not null references private.members(id),
  loser uuid not null references private.members(id),
  submitter uuid references private.members(id),
  submitted_by uuid references auth.users(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','confirmed','disputed','void')),
  created timestamptz not null default now(),
  confirmed timestamptz,
  confirmation_order bigint unique,
  note text not null default '' check (length(note)<=240),
  delta double precision,
  winner_after double precision,
  loser_after double precision,
  check(winner<>loser),
  check(status<>'confirmed' or (confirmed is not null and confirmation_order is not null))
);
create table private.audit (
  id bigint generated always as identity primary key,
  actor uuid references auth.users(id) on delete set null,
  action text not null,
  target uuid,
  created timestamptz not null default now()
);
alter table private.admins enable row level security;
alter table private.members enable row level security;
alter table private.matches enable row level security;
alter table private.audit enable row level security;
revoke all on all tables in schema private from public,anon,authenticated;
revoke all on all sequences in schema private from public,anon,authenticated;

create function private.recalculate() returns void
language plpgsql security definer set search_path = '' as $$
declare g record; a double precision; b double precision; change double precision;
begin
  update private.members set rating=1000,wins=0,losses=0,delta=0;
  update private.matches set delta=null,winner_after=null,loser_after=null;
  for g in select * from private.matches where status='confirmed' order by confirmation_order,id loop
    select rating into a from private.members where id=g.winner;
    select rating into b from private.members where id=g.loser;
    change:=32*(1-1/(1+power(10.0,(b-a)/400.0)));
    update private.members set rating=a+change,wins=wins+1,delta=change where id=g.winner;
    update private.members set rating=b-change,losses=losses+1,delta=-change where id=g.loser;
    update private.matches set delta=change,winner_after=a+change,loser_after=b-change where id=g.id;
  end loop;
end; $$;
revoke all on function private.recalculate() from public,anon,authenticated;

create function public.get_house() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=auth.uid(); em text; is_admin boolean; me uuid; players jsonb; games jsonb;
begin
  if uid is null then raise exception 'Please sign in to continue.' using errcode='42501'; end if;
  -- Read verified email from Auth rather than trusting editable user metadata.
  select lower(email) into em from auth.users where id=uid and email_confirmed_at is not null;
  if em is null then raise exception 'A verified email is required.' using errcode='42501'; end if;
  select exists(select 1 from private.admins where user_id=uid) into is_admin;
  select id into me from private.members where email=em and active;
  if not is_admin and me is null then raise exception 'Your account is not on the active member list. Ask the administrator to add your Google email.' using errcode='42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'name',m.name,'email',case when is_admin then m.email else null end,
    'active',m.active,'rating',m.rating,'wins',m.wins,'losses',m.losses,'delta',m.delta,
    'history',(select coalesce(jsonb_agg(jsonb_build_object('id',g.id,
      'rating',case when g.winner=m.id then g.winner_after else g.loser_after end,
      'delta',case when g.winner=m.id then g.delta else -g.delta end) order by g.confirmation_order),'[]'::jsonb)
      from private.matches g where g.status='confirmed' and m.id in(g.winner,g.loser))
  ) order by m.rating desc,m.name,m.id),'[]'::jsonb) into players from private.members m;
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,
    'submitter',g.submitter,'status',g.status,'created',g.created,'confirmed',g.confirmed,'note',g.note,'delta',g.delta)
    order by g.created desc,g.id),'[]'::jsonb) into games from private.matches g;
  return jsonb_build_object('admin',is_admin,'me',me,'email',em,'players',players,'matches',games);
end; $$;

create function public.house_action(params jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid:=auth.uid(); em text; is_admin boolean; me uuid;
  action text:=params->>'action'; target uuid; a uuid; b uuid; nm text; member_email text; g private.matches%rowtype;
begin
  if uid is null then raise exception 'Please sign in to continue.' using errcode='42501'; end if;
  -- All app mutations serialize, including void/replay. Prevents double confirmations and stale ratings.
  perform pg_advisory_xact_lock(84201935);
  select lower(email) into em from auth.users where id=uid and email_confirmed_at is not null;
  if em is null then raise exception 'A verified email is required.' using errcode='42501'; end if;
  select exists(select 1 from private.admins where user_id=uid) into is_admin;
  select id into me from private.members where email=em and active;
  if not is_admin and me is null then raise exception 'Active membership required.' using errcode='42501'; end if;
  if action='add' then
    if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
    nm:=btrim(params->>'name'); member_email:=nullif(lower(btrim(params->>'email')),'');
    if nm is null or length(nm) not between 1 and 60 then raise exception 'Enter a name of 1–60 characters.'; end if;
    if member_email is not null and member_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid email.'; end if;
    if exists(select 1 from private.members where email=member_email) then raise exception 'That email is already assigned to a member.'; end if;
    insert into private.members(name,email) values(nm,member_email) returning id into target;
  elsif action='edit' then
    if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
    target:=(params->>'id')::uuid;
    if jsonb_typeof(params->'active') is distinct from 'boolean' then raise exception 'Active must be true or false.'; end if;
    update private.members set active=(params->>'active')::boolean where id=target;
    if not found then raise exception 'Member not found.'; end if;
  elsif action='submit' then
    target:=(params->>'id')::uuid; a:=(params->>'winner')::uuid; b:=(params->>'loser')::uuid;
    if target is null or a is null or b is null or a=b then raise exception 'Select two different active players.'; end if;
    if not exists(select 1 from private.members where id=a and active) or not exists(select 1 from private.members where id=b and active) then raise exception 'Select two different active players.'; end if;
    if not is_admin and me is distinct from a and me is distinct from b then raise exception 'You can only submit your own games.' using errcode='42501'; end if;
    if length(coalesce(params->>'note',''))>240 then raise exception 'Notes must be 240 characters or fewer.'; end if;
    select * into g from private.matches where id=target;
    if found then
      if g.submitted_by=uid and g.winner=a and g.loser=b and g.note=coalesce(params->>'note','') then return jsonb_build_object('ok',true); end if;
      raise exception 'Match ID already used.';
    end if;
    insert into private.matches(id,winner,loser,submitter,submitted_by,note)
      values(target,a,b,me,uid,coalesce(params->>'note',''));
  elsif action in ('confirm','dispute','void') then
    target:=(params->>'id')::uuid;
    select * into g from private.matches where id=target for update;
    if not found then raise exception 'Game not found.'; end if;
    if action='void' then
      if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
      if g.status='void' then raise exception 'This result has already been voided.'; end if;
      update private.matches set status='void' where id=target;
      perform private.recalculate();
    else
      if not is_admin and (me is null or (me<>g.winner and me<>g.loser) or me is not distinct from g.submitter or uid is not distinct from g.submitted_by) then
        raise exception 'Only the opponent or admin can review this result.' using errcode='42501';
      end if;
      if g.status<>'pending' and not(is_admin and g.status='disputed' and action='confirm') then raise exception 'This result has already been reviewed.'; end if;
      if action='confirm' then
        update private.matches set status='confirmed',confirmed=clock_timestamp(),confirmation_order=nextval('private.confirmation_order') where id=target;
        perform private.recalculate();
      else update private.matches set status='disputed' where id=target;
      end if;
    end if;
  else raise exception 'Unknown action.';
  end if;
  insert into private.audit(actor,action,target) values(uid,action,target);
  return jsonb_build_object('ok',true);
end; $$;
revoke all on function public.get_house() from public,anon,authenticated;
revoke all on function public.house_action(jsonb) from public,anon,authenticated;
grant execute on function public.get_house() to authenticated;
grant execute on function public.house_action(jsonb) to authenticated;
commit;
