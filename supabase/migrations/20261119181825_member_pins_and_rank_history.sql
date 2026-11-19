-- Member PINs are bcrypt hashes; legacy name-only sessions must complete setup.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
alter table private.members add column pin_hash text;
alter table private.members add column joined_at timestamptz;
update private.members m set joined_at=coalesce((select min(created) from private.audit where target=m.id and action='add'),'-infinity'::timestamptz) where joined_at is null;
alter table private.members alter column joined_at set default now();
alter table private.members alter column joined_at set not null;
alter table private.member_sessions add column pin_verified boolean not null default false;
create index audit_target_created_idx on private.audit(target,created,id);

create function private.issue_member_session(person uuid,rotate boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare token text; nm text;
begin
 if rotate then delete from private.member_sessions where member_id=person;
 else delete from private.member_sessions where member_id=person and expires_at<=now(); end if;
 token:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 insert into private.member_sessions(token_hash,member_id,pin_verified) values(encode(sha256(convert_to(token,'UTF8')),'hex'),person,true);
 select name into nm from private.members where id=person;
 return jsonb_build_object('token',token,'id',person,'name',nm);
end; $$;
revoke all on function private.issue_member_session(uuid,boolean) from public,anon,authenticated;

create function private.pin_login(first_name text,last_name text,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare full_name text; person private.members%rowtype; pin text:=params->>'pin'; setup boolean:=coalesce((params->>'setup')::boolean,false);
begin
 full_name:=regexp_replace(btrim(coalesce(first_name,'')||' '||coalesce(last_name,'')),'[[:space:]]+',' ','g');
 if nullif(btrim(first_name),'') is null or nullif(btrim(last_name),'') is null or length(full_name)>60 then raise exception 'Enter your first and last name.'; end if;
 -- The row lock makes concurrent first-time setup atomic: only the first claim succeeds.
 select * into person from private.members where active and lower(regexp_replace(btrim(name),'[[:space:]]+',' ','g'))=lower(full_name) for update;
 if not found then raise exception 'That name is not on the active member list. Ask an admin to add you.' using errcode='42501'; end if;
 if pin is null then return jsonb_build_object('name',person.name,'needs_pin_setup',person.pin_hash is null); end if;
 if pin !~ '^[0-9]{6}$' then raise exception 'Enter exactly six digits.'; end if;
 if setup then
  if person.pin_hash is not null then raise exception 'A PIN is already set. Sign in with your existing PIN.'; end if;
  update private.members set pin_hash=extensions.crypt(pin,extensions.gen_salt('bf',10)) where id=person.id;
  insert into private.audit(action,target,member_actor) values('set_pin',person.id,person.id);
  return private.issue_member_session(person.id,true);
 end if;
 if person.pin_hash is null then raise exception 'Create your six-digit PIN first.'; end if;
 if extensions.crypt(pin,person.pin_hash) is distinct from person.pin_hash then raise exception 'Incorrect PIN. Try again or ask an admin to reset it.' using errcode='42501'; end if;
 return private.issue_member_session(person.id);
end; $$;
revoke all on function private.pin_login(text,text,jsonb) from public,anon,authenticated;
-- The old name-only endpoint now reports setup state, never an authenticated session.
create or replace function private.unlimited_name_sign_in(first_name text,last_name text) returns jsonb
language sql security definer set search_path='' as $$select private.pin_login(first_name,last_name,null)$$;

create or replace function private.resolve_member(session_token text) returns uuid
language plpgsql security definer set search_path='' as $$
declare member uuid;
begin
 if session_token is null or length(session_token)<>64 then raise exception 'Please sign in again.' using errcode='42501'; end if;
 select s.member_id into member from private.member_sessions s join private.members m on m.id=s.member_id
 where s.token_hash=encode(sha256(convert_to(session_token,'UTF8')),'hex') and s.expires_at>now() and m.active
 and (s.pin_verified or m.pin_hash is null);
 if member is null then raise exception 'Your session expired or your account is inactive. Please sign in again.' using errcode='42501'; end if;
 return member;
end; $$;

create function private.change_member_pin(me uuid,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare old_hash text; new_pin text:=params->>'new_pin'; current_pin text:=params->>'current_pin';
begin
 select pin_hash into old_hash from private.members where id=me and active for update;
 if not found then raise exception 'Active membership required.' using errcode='42501'; end if;
 if new_pin is null or new_pin !~ '^[0-9]{6}$' then raise exception 'Enter exactly six digits for your new PIN.'; end if;
 if old_hash is not null and (current_pin is null or current_pin !~ '^[0-9]{6}$' or extensions.crypt(current_pin,old_hash) is distinct from old_hash) then raise exception 'Current PIN is incorrect.' using errcode='42501'; end if;
 update private.members set pin_hash=extensions.crypt(new_pin,extensions.gen_salt('bf',10)) where id=me;
 insert into private.audit(action,target,member_actor) values(case when old_hash is null then 'set_pin' else 'change_pin' end,me,me);
 return private.issue_member_session(me,true);
end; $$;
revoke all on function private.change_member_pin(uuid,jsonb) from public,anon,authenticated;

create or replace function private.unlimited_member_action(session_token text,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare me uuid;
begin
 perform pg_advisory_xact_lock(84201935);
 me:=private.resolve_member(session_token);
 if params->>'action'='change_pin' then return private.change_member_pin(me,params); end if;
 if params->>'action'='reset_pin' then raise exception 'Admin access required.' using errcode='42501'; end if;
 if not exists(select 1 from private.members where id=me and pin_hash is not null) then raise exception 'Create your six-digit PIN before continuing.' using errcode='42501'; end if;
 return private.perform_action(me,null,false,params);
end; $$;

create or replace function private.unlimited_house_action(params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); em text; is_admin boolean; me uuid;
begin
  if uid is null then raise exception 'Please sign in to continue.' using errcode='42501'; end if;
  select lower(email) into em from auth.users where id=uid and email_confirmed_at is not null;
  if em is null then raise exception 'A verified email is required.' using errcode='42501'; end if;
  select exists(select 1 from private.admins where user_id=uid) into is_admin;
  select id into me from private.members where email=em and active;
  if not is_admin and me is null then raise exception 'Active membership required.' using errcode='42501'; end if;
  if params->>'action'='reset_pin' then
    if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
    perform pg_advisory_xact_lock(84201935);
    update private.members set pin_hash=null where id=(params->>'id')::uuid;
    if not found then raise exception 'Member not found.'; end if;
    delete from private.member_sessions where member_id=(params->>'id')::uuid;
    insert into private.audit(actor,action,target) values(uid,'reset_pin',(params->>'id')::uuid);
    return jsonb_build_object('ok',true);
  end if;
  return private.perform_action(me,uid,is_admin,params);
end; $$;

create or replace function private.guarded_rpc(route text,token text default null,params jsonb default null,first_name text default null,last_name text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare retry integer; actor text; budget text; ceiling integer;
begin
  -- This shared ceiling also bounds unknown names, invalid tokens, and sessions rotated by callers.
  retry:=private.take_rpc_budget('api-global','all',1200,60);
  if retry>0 then return private.rpc_failure('Too many requests. Try again in '||retry||' seconds.','RATE_LIMITED',retry); end if;

  if route='name_sign_in' then
    retry:=private.take_rpc_budget('login-global','all',300,60);
    if retry=0 then
      actor:=lower(regexp_replace(btrim(coalesce(first_name,'')||' '||coalesce(last_name,'')),'[[:space:]]+',' ','g'));
      retry:=private.take_rpc_budget('login-name',actor,6,60);
      if retry=0 then retry:=private.take_rpc_budget('login-hour',actor,30,3600); end if;
    end if;
  else
    -- Resolve identity before selecting the per-player budget. No actor/admin flag is trusted from params.
    begin
      if route in ('member_house','member_action') then actor:=private.resolve_member(token)::text;
      else
        if auth.uid() is null then raise exception 'Please sign in to continue.' using errcode='42501'; end if;
        actor:=auth.uid()::text;
      end if;
    exception when others then return private.rpc_failure(sqlerrm,sqlstate); end;
    if route in ('member_house','get_house') then budget:='read';ceiling:=120;
    elsif route='member_action' then budget:='member-write';ceiling:=30;
    else budget:='admin-write';ceiling:=60;
    end if;
    retry:=private.take_rpc_budget(budget,actor,ceiling,60);
    if retry=0 and route='member_action' and params->>'action'='change_pin' then
      retry:=private.take_rpc_budget('pin-change',actor,6,60);
      if retry=0 then retry:=private.take_rpc_budget('pin-change-hour',actor,30,3600); end if;
    end if;
    if retry=0 and route in ('member_action','house_action') and params->>'action'='submit' then
      retry:=private.take_rpc_budget('game-submit',actor,5,60);
    end if;
  end if;
  if retry>0 then return private.rpc_failure('Too many requests. Try again in '||retry||' seconds.','RATE_LIMITED',retry); end if;

  -- Catch business errors AFTER charging the budgets. A RAISE from this block rolls back only
  -- the business operation, so failed sign-ins and invalid requests still consume their budget.
  -- Setting an HTTP error response instead of raising preserves counters at transaction commit.
  begin
    case route
      when 'name_sign_in' then return private.pin_login(first_name,last_name,params);
      when 'member_house' then return private.unlimited_member_house(token);
      when 'member_action' then return private.unlimited_member_action(token,params);
      when 'get_house' then return private.unlimited_get_house();
      when 'house_action' then return private.unlimited_house_action(params);
      else raise exception 'Unknown request.';
    end case;
  exception when others then return private.rpc_failure(sqlerrm,sqlstate); end;
end; $$;
create function public.member_login(first_name text,last_name text,pin text default null,setup boolean default false) returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc('name_sign_in',null,jsonb_build_object('pin',pin,'setup',setup),first_name,last_name)$$;
revoke all on function public.member_login(text,text,text,boolean) from public,anon,authenticated;
grant execute on function public.member_login(text,text,text,boolean) to anon,authenticated;

-- Reconstruct Elo at a cutoff from the audited review state, including historical voids.
-- Rank movement compares the current active roster; later joiners have no previous rank.
create function private.rankings_at(cutoff timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare ratings jsonb; g record; a double precision; b double precision; change double precision; result jsonb;
begin
 select coalesce(jsonb_object_agg(id::text,1000),'{}'::jsonb) into ratings from private.members;
 for g in
  select m.* from private.matches m
  left join lateral (select action from private.audit where target=m.id and created<=cutoff
    and action in ('submit','confirm','dispute','void','unvoid') order by created desc,id desc limit 1) last_action on true
  left join lateral (select action from private.audit where target=m.id and created<=cutoff
    and action in ('submit','confirm','dispute') order by created desc,id desc limit 1) base_action on true
  where m.confirmed<=cutoff and m.confirmation_order is not null
   and case when last_action.action='unvoid' then base_action.action='confirm'
     when last_action.action is null then true else last_action.action='confirm' end
  order by m.confirmation_order,m.id
 loop
  a:=(ratings->>g.winner::text)::double precision; b:=(ratings->>g.loser::text)::double precision;
  change:=32*(1-1/(1+power(10.0,(b-a)/400.0)));
  ratings:=jsonb_set(ratings,array[g.winner::text],to_jsonb(a+change));
  ratings:=jsonb_set(ratings,array[g.loser::text],to_jsonb(b-change));
 end loop;
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'rank',rank,'rating',rating) order by rank),'[]'::jsonb) into result from (
  select id,(ratings->>id::text)::double precision rating,row_number() over(order by (ratings->>id::text)::double precision desc,name,id) rank
  from private.members where active and joined_at<=cutoff
 ) ranked;
 return result;
end; $$;
revoke all on function private.rankings_at(timestamptz) from public,anon,authenticated;

create or replace function private.house_data(me uuid,is_admin boolean,em text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare players jsonb; games jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',m.id,'name',m.name,'email',case when is_admin then m.email else null end,
    'active',m.active,'rating',m.rating,'wins',m.wins,'losses',m.losses,'delta',m.delta,
    'history',(select coalesce(jsonb_agg(jsonb_build_object('id',g.id,
      'rating',case when g.winner=m.id then g.winner_after else g.loser_after end,
      'confirmed',g.confirmed,'delta',case when g.winner=m.id then g.delta else -g.delta end) order by g.confirmation_order),'[]'::jsonb)
      from private.matches g where g.status='confirmed' and m.id in(g.winner,g.loser))
  ) order by m.rating desc,m.name,m.id),'[]'::jsonb) into players from private.members m;
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,
    'submitter',g.submitter,'status',g.status,'created',g.created,'confirmed',g.confirmed,'note',g.note,'delta',g.delta)
    order by g.created desc,g.id),'[]'::jsonb) into games from private.matches g;
  return jsonb_build_object('admin',is_admin,'me',me,'email',em,'players',players,'matches',games,
    'pin_required',not is_admin and exists(select 1 from private.members where id=me and pin_hash is null),
    'rank_baselines',jsonb_build_object('day',private.rankings_at(now()-interval '24 hours'),'week',private.rankings_at(now()-interval '7 days'),'month',private.rankings_at(now()-interval '30 days')));
end; $$;
revoke all on function private.house_data(uuid,boolean,text) from public,anon,authenticated;

create or replace function private.unlimited_get_house() returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); em text; is_admin boolean; me uuid;
begin
 if uid is null then raise exception 'Please sign in to continue.' using errcode='42501'; end if;
 select lower(email) into em from auth.users where id=uid and email_confirmed_at is not null;
 if em is null then raise exception 'A verified email is required.' using errcode='42501'; end if;
 select exists(select 1 from private.admins where user_id=uid) into is_admin;
 select id into me from private.members where email=em and active;
 if not is_admin and me is null then raise exception 'Active membership required.' using errcode='42501'; end if;
 return private.house_data(me,is_admin,em);
end; $$;
notify pgrst,'reload schema';
