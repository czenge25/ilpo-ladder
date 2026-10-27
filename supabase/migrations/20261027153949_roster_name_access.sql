-- Name-based member access. Admin operations continue to require Supabase Auth.
-- Apply after 001_schema.sql.
create table private.member_sessions (
  token_hash text primary key,
  member_id uuid not null references private.members(id) on delete cascade,
  expires_at timestamptz not null default (now()+interval '30 days'),
  created_at timestamptz not null default now()
);
create index member_sessions_member_idx on private.member_sessions(member_id);
alter table private.member_sessions enable row level security;
revoke all on private.member_sessions from public,anon,authenticated;
alter table private.audit add column member_actor uuid references private.members(id);
create unique index members_active_normalized_name_unique on private.members
  (lower(regexp_replace(btrim(name),'[[:space:]]+',' ','g'))) where active;

create function private.resolve_member(session_token text) returns uuid
language plpgsql security definer set search_path='' as $$
declare member uuid;
begin
  if session_token is null or length(session_token)<>64 then raise exception 'Please sign in again.' using errcode='42501'; end if;
  select s.member_id into member from private.member_sessions s
    join private.members m on m.id=s.member_id
    where s.token_hash=encode(sha256(convert_to(session_token,'UTF8')),'hex') and s.expires_at>now() and m.active;
  if member is null then raise exception 'Your session expired or your account is inactive. Please sign in again.' using errcode='42501'; end if;
  return member;
end; $$;
revoke all on function private.resolve_member(text) from public,anon,authenticated;

create function private.house_data(me uuid,is_admin boolean,em text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare players jsonb; games jsonb;
begin
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
revoke all on function private.house_data(uuid,boolean,text) from public,anon,authenticated;

create function private.perform_action(me uuid,uid uuid,is_admin boolean,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare action text:=params->>'action'; target uuid; a uuid; b uuid; nm text; member_email text; g private.matches%rowtype;
begin
  perform pg_advisory_xact_lock(84201935);
  if action='add' then
    if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
    nm:=btrim(params->>'name'); member_email:=nullif(lower(btrim(params->>'email')),'');
    if nm is null or length(nm) not between 1 and 60 or nm !~ '[[:space:]]' then raise exception 'Enter a first and last name (60 characters maximum).'; end if;
    nm:=regexp_replace(nm,'[[:space:]]+',' ','g');
    if member_email is not null and member_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid email.'; end if;
    if exists(select 1 from private.members where email=member_email) then raise exception 'That email is already assigned to a member.'; end if;
    insert into private.members(name,email) values(nm,member_email) returning id into target;
  elsif action='edit' then
    if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
    target:=(params->>'id')::uuid;
    if jsonb_typeof(params->'active') is distinct from 'boolean' then raise exception 'Active must be true or false.'; end if;
    update private.members set active=(params->>'active')::boolean where id=target;
    if not found then raise exception 'Member not found.'; end if;
    if not (params->>'active')::boolean then delete from private.member_sessions where member_id=target; end if;
  elsif action='submit' then
    target:=(params->>'id')::uuid; a:=(params->>'winner')::uuid; b:=(params->>'loser')::uuid;
    if target is null or a is null or b is null or a=b then raise exception 'Select two different active players.'; end if;
    if not exists(select 1 from private.members where id=a and active) or not exists(select 1 from private.members where id=b and active) then raise exception 'Select two different active players.'; end if;
    if not is_admin and me is distinct from a and me is distinct from b then raise exception 'You can only submit your own games.' using errcode='42501'; end if;
    if length(coalesce(params->>'note',''))>240 then raise exception 'Notes must be 240 characters or fewer.'; end if;
    select * into g from private.matches where id=target;
    if found then
      if ((uid is not null and g.submitted_by=uid) or (uid is null and g.submitted_by is null and g.submitter=me)) and g.winner=a and g.loser=b and g.note=coalesce(params->>'note','') then return jsonb_build_object('ok',true); end if;
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
      if not is_admin and (me is null or (me<>g.winner and me<>g.loser) or me is not distinct from g.submitter or (uid is not null and uid is not distinct from g.submitted_by)) then
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
  insert into private.audit(actor,member_actor,action,target) values(uid,me,action,target);
  return jsonb_build_object('ok',true);
exception when unique_violation then raise exception 'An active member with that name or email already exists.';
end; $$;
revoke all on function private.perform_action(uuid,uuid,boolean,jsonb) from public,anon,authenticated;

create or replace function public.house_action(params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); em text; is_admin boolean; me uuid;
begin
  if uid is null then raise exception 'Please sign in to continue.' using errcode='42501'; end if;
  select lower(email) into em from auth.users where id=uid and email_confirmed_at is not null;
  if em is null then raise exception 'A verified email is required.' using errcode='42501'; end if;
  select exists(select 1 from private.admins where user_id=uid) into is_admin;
  select id into me from private.members where email=em and active;
  if not is_admin and me is null then raise exception 'Active membership required.' using errcode='42501'; end if;
  return private.perform_action(me,uid,is_admin,params);
end; $$;

create function public.name_sign_in(first_name text,last_name text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare full_name text; person private.members%rowtype; token text;
begin
  full_name:=regexp_replace(btrim(coalesce(first_name,'')||' '||coalesce(last_name,'')),'[[:space:]]+',' ','g');
  if nullif(btrim(first_name),'') is null or nullif(btrim(last_name),'') is null or length(full_name)>60 then
    raise exception 'Enter your first and last name.';
  end if;
  select * into person from private.members where active and
    lower(regexp_replace(btrim(name),'[[:space:]]+',' ','g'))=lower(full_name);
  if not found then raise exception 'That name is not on the active member list. Ask an admin to add you.' using errcode='42501'; end if;
  token:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  delete from private.member_sessions where member_id=person.id and expires_at<=now();
  insert into private.member_sessions(token_hash,member_id) values(encode(sha256(convert_to(token,'UTF8')),'hex'),person.id);
  return jsonb_build_object('token',token,'id',person.id,'name',person.name);
end; $$;

create function public.member_house(session_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare me uuid;
begin
  me:=private.resolve_member(session_token);
  return private.house_data(me,false,null);
end; $$;

create function public.member_action(session_token text,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare me uuid;
begin
  -- Lock before checking membership so a simultaneous deactivation cannot permit a write.
  perform pg_advisory_xact_lock(84201935);
  me:=private.resolve_member(session_token);
  return private.perform_action(me,null,false,params);
end; $$;

create function public.name_sign_out(session_token text) returns void
language plpgsql security definer set search_path='' as $$
begin
  delete from private.member_sessions where token_hash=encode(sha256(convert_to(session_token,'UTF8')),'hex');
end; $$;

revoke all on function public.name_sign_in(text,text) from public,anon,authenticated;
revoke all on function public.member_house(text) from public,anon,authenticated;
revoke all on function public.member_action(text,jsonb) from public,anon,authenticated;
revoke all on function public.name_sign_out(text) from public,anon,authenticated;
grant execute on function public.name_sign_in(text,text) to anon,authenticated;
grant execute on function public.member_house(text) to anon,authenticated;
grant execute on function public.member_action(text,jsonb) to anon,authenticated;
grant execute on function public.name_sign_out(text) to anon,authenticated;
