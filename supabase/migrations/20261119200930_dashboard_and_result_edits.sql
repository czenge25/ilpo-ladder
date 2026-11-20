-- Match dates are distinct from submission time and stable Elo sequence order.
alter table private.matches add column played_at timestamptz;
update private.matches set played_at=created where played_at is null;
alter table private.matches alter column played_at set default now();
alter table private.matches alter column played_at set not null;
create table private.result_edits (
 id bigint generated always as identity primary key,
 match_id uuid not null references private.matches(id),
 actor uuid references auth.users(id) on delete set null,
 edited_at timestamptz not null default clock_timestamp(),
 before_result jsonb not null,
 after_result jsonb not null
);
alter table private.result_edits enable row level security;
revoke all on private.result_edits from public,anon,authenticated;
revoke all on sequence private.result_edits_id_seq from public,anon,authenticated;
create index result_edits_match_time_idx on private.result_edits(match_id,edited_at,id);

create or replace function private.perform_action(me uuid,uid uuid,is_admin boolean,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare action text:=params->>'action'; target uuid; a uuid; b uuid; nm text; member_email text; g private.matches%rowtype; new_note text; new_date timestamptz;
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
    insert into private.matches(id,winner,loser,submitter,submitted_by,note,status,confirmed,confirmation_order)
      values(target,a,b,me,uid,coalesce(params->>'note',''),'confirmed',clock_timestamp(),nextval('private.confirmation_order'));
    perform private.recalculate();
  elsif action='edit_result' then
    if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
    target:=(params->>'id')::uuid;
    select * into g from private.matches where id=target for update;
    if not found then raise exception 'Game not found.'; end if;
    a:=coalesce((params->>'winner')::uuid,g.winner); b:=coalesce((params->>'loser')::uuid,g.loser);
    if a=b then raise exception 'Select two different players.'; end if;
    if not exists(select 1 from private.members where id=a and (active or id in(g.winner,g.loser))) or not exists(select 1 from private.members where id=b and (active or id in(g.winner,g.loser))) then raise exception 'Select active players or keep the original players.'; end if;
    new_note:=case when params ? 'note' then coalesce(params->>'note','') else g.note end;
    if length(new_note)>240 then raise exception 'Notes must be 240 characters or fewer.'; end if;
    begin new_date:=coalesce(nullif(params->>'played_at','')::timestamptz,g.played_at);
    exception when invalid_datetime_format or datetime_field_overflow then raise exception 'Enter a valid match date.'; end;
    if not isfinite(new_date) or new_date>clock_timestamp()+interval '5 minutes' then raise exception 'The match date cannot be in the future.'; end if;
    update private.matches set winner=a,loser=b,note=new_note,played_at=new_date where id=target;
    perform private.recalculate();
    insert into private.result_edits(match_id,actor,before_result,after_result)
      select target,uid,to_jsonb(g),to_jsonb(m) from private.matches m where id=target;
  elsif action in ('dispute','resolve','void','unvoid') then
    target:=(params->>'id')::uuid;
    select * into g from private.matches where id=target for update;
    if not found then raise exception 'Game not found.'; end if;
    if action='void' then
      if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
      if g.status='void' then raise exception 'This result has already been voided.'; end if;
      update private.matches set status_before_void=g.status,status='void' where id=target;
    elsif action='unvoid' then
      if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
      if g.status<>'void' then raise exception 'This result is not voided.'; end if;
      update private.matches set status=case when g.status_before_void='disputed' then 'disputed' else 'confirmed' end,status_before_void=null,
        confirmed=coalesce(g.confirmed,clock_timestamp()),confirmation_order=coalesce(g.confirmation_order,nextval('private.confirmation_order')) where id=target;
    elsif action='resolve' then
      if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
      if g.status<>'disputed' then raise exception 'This result is not disputed.'; end if;
      update private.matches set status='confirmed',confirmed=coalesce(g.confirmed,clock_timestamp()),
        confirmation_order=coalesce(g.confirmation_order,nextval('private.confirmation_order')) where id=target;
    else
      if not is_admin and (me is null or (me<>g.winner and me<>g.loser)) then raise exception 'Only a player in this game or an admin can dispute it.' using errcode='42501'; end if;
      if g.status<>'confirmed' then raise exception 'Only recorded results can be disputed.'; end if;
      update private.matches set status='disputed' where id=target;
    end if;
    perform private.recalculate();
  else raise exception 'Unknown action.';
  end if;
  insert into private.audit(actor,member_actor,action,target) values(uid,me,action,target);
  return jsonb_build_object('ok',true);
exception when unique_violation then raise exception 'An active member with that name or email already exists.';
end; $$;
revoke all on function private.perform_action(uuid,uuid,boolean,jsonb) from public,anon,authenticated;

create or replace function private.rankings_at(cutoff timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare ratings jsonb; g record; a double precision; b double precision; change double precision; result jsonb;
begin
 select coalesce(jsonb_object_agg(id::text,1000),'{}'::jsonb) into ratings from private.members;
 for g in
  select m.* from (
   select original.id,
    case when edit.before_result is null then original.winner else (edit.before_result->>'winner')::uuid end winner,
    case when edit.before_result is null then original.loser else (edit.before_result->>'loser')::uuid end loser,
    case when edit.before_result is null then original.confirmed else (edit.before_result->>'confirmed')::timestamptz end confirmed,
    case when edit.before_result is null then original.confirmation_order else (edit.before_result->>'confirmation_order')::bigint end confirmation_order
   from private.matches original
   left join lateral (select before_result from private.result_edits where match_id=original.id and edited_at>cutoff order by edited_at,id limit 1) edit on true
  ) m
  left join lateral (select action from private.audit where target=m.id and created<=cutoff
    and action in ('submit','confirm','auto_record','dispute','resolve','void','unvoid') order by created desc,id desc limit 1) last_action on true
  left join lateral (select action from private.audit where target=m.id and created<=cutoff
    and action in ('submit','confirm','auto_record','dispute','resolve') order by created desc,id desc limit 1) base_action on true
  where m.confirmed<=cutoff and m.confirmation_order is not null
   and case when last_action.action='unvoid' then base_action.action in ('submit','confirm','auto_record','resolve')
     when last_action.action is null then true else last_action.action in ('submit','confirm','auto_record','resolve') end
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


create or replace function private.history_page(session_token text,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare total integer; requested integer:=coalesce((params->>'page')::integer,1); actual integer; games jsonb; em text;
begin
 if session_token is not null then perform private.resolve_member(session_token);
 else
  select lower(email) into em from auth.users where id=auth.uid() and email_confirmed_at is not null;
  if em is null or (not exists(select 1 from private.admins where user_id=auth.uid()) and not exists(select 1 from private.members where email=em and active)) then raise exception 'Please sign in to continue.' using errcode='42501'; end if;
 end if;
 if requested<1 then raise exception 'Page must be at least 1.'; end if;
 select count(*) into total from private.matches where status='confirmed';
 actual:=least(requested,greatest(1,(total+9)/10));
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'submitter',g.submitter,'status',g.status,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,'delta',g.delta) order by g.created desc,g.id),'[]'::jsonb) into games
 from (select * from private.matches where status='confirmed' order by created desc,id limit 10 offset (actual-1)*10) g;
 return jsonb_build_object('matches',games,'total',total,'page',actual,'page_size',10);
end; $$;
revoke all on function private.history_page(text,jsonb) from public,anon,authenticated;


create or replace function private.house_data(me uuid,is_admin boolean,em text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare players jsonb; games jsonb; totals jsonb; h2h jsonb;
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
    'submitter',g.submitter,'status',g.status,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,'delta',g.delta)
    order by g.created desc,g.id),'[]'::jsonb) into games from (select * from private.matches where status in ('disputed','void')
    union all (select * from private.matches where status='confirmed' order by created desc,id limit 3)) g;
  select jsonb_build_object('recorded',count(*) filter(where status='confirmed'),'disputed',count(*) filter(where status='disputed'),'voided',count(*) filter(where status='void')) into totals from private.matches;
  select coalesce(jsonb_agg(jsonb_build_object('winner',winner,'loser',loser,'wins',wins)),'[]'::jsonb) into h2h from (select winner,loser,count(*) wins from private.matches where status='confirmed' group by winner,loser) results;
  return jsonb_build_object('admin',is_admin,'me',me,'email',em,'players',players,'matches',games,'match_counts',totals,'head_to_head',h2h,
    'pin_required',not is_admin and exists(select 1 from private.members where id=me and pin_hash is null),
    'rank_baselines',jsonb_build_object('day',private.rankings_at(now()-interval '24 hours'),'week',private.rankings_at(now()-interval '7 days'),'month',private.rankings_at(now()-interval '30 days')));
end; $$;
revoke all on function private.house_data(uuid,boolean,text) from public,anon,authenticated;


create or replace function private.summary_data(session_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb; players jsonb; games jsonb; totals jsonb; revision text;
begin
 context:=private.read_context(session_token);
 select coalesce(max(id),0)::text into revision from private.audit;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'email',case when (context->>'admin')::boolean then m.email else null end,
  'active',m.active,'rating',m.rating,'wins',m.wins,'losses',m.losses,'delta',m.delta) order by m.rating desc,m.name,m.id),'[]'::jsonb) into players from private.members m;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'submitter',g.submitter,'status',g.status,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,'delta',g.delta) order by g.created desc,g.id),'[]'::jsonb) into games
 from (select * from private.matches where status in ('disputed','void') union all (select * from private.matches where status='confirmed' order by created desc,id limit 3)) g;
 select jsonb_build_object('recorded',count(*) filter(where status='confirmed'),'disputed',count(*) filter(where status='disputed'),'voided',count(*) filter(where status='void')) into totals from private.matches;
 return context||jsonb_build_object('players',players,'matches',games,'match_counts',totals,'revision',revision,
  'pin_required',not(context->>'admin')::boolean and exists(select 1 from private.members where id=(context->>'me')::uuid and pin_hash is null),
  'rank_baselines',jsonb_build_object('day',private.rankings_at(now()-interval '24 hours'),'week',private.rankings_at(now()-interval '7 days'),'month',private.rankings_at(now()-interval '30 days')));
end; $$;
revoke all on function private.summary_data(text) from public,anon,authenticated;


create or replace function private.player_results_data(session_token text,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person uuid:=(params->>'player_id')::uuid; requested integer:=coalesce((params->>'page')::integer,1); actual integer; total integer; games jsonb;
begin
 perform private.read_context(session_token);
 if not exists(select 1 from private.members where id=person) then raise exception 'Player not found.'; end if;
 if requested<1 then raise exception 'Page must be at least 1.'; end if;
 select count(*) into total from private.matches where status='confirmed' and person in(winner,loser);
 actual:=least(requested,greatest(1,(total+9)/10));
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'opponent',m.name,'won',g.winner=person,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,
  'rating',case when g.winner=person then g.winner_after else g.loser_after end,'delta',case when g.winner=person then g.delta else -g.delta end) order by g.confirmation_order desc,g.id desc),'[]'::jsonb) into games
 from (select * from private.matches where status='confirmed' and person in(winner,loser) order by confirmation_order desc,id desc limit 10 offset (actual-1)*10) g
 join private.members m on m.id=case when g.winner=person then g.loser else g.winner end;
 return jsonb_build_object('matches',games,'total',total,'page',actual,'page_size',10);
end; $$;
revoke all on function private.player_results_data(text,jsonb) from public,anon,authenticated;


create function private.dashboard_data(session_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb; me uuid; games jsonb; favorite jsonb; current_win boolean; count_streak integer:=0; entry record;
begin
 context:=private.read_context(session_token); me:=(context->>'me')::uuid;
 if me is null then raise exception 'This account has no linked player.' using errcode='42501'; end if;
 for entry in select winner=me won from private.matches where status='confirmed' and me in(winner,loser) order by confirmation_order desc,id desc loop
  if current_win is null then current_win:=entry.won; end if;
  exit when entry.won<>current_win;
  count_streak:=count_streak+1;
 end loop;
 select jsonb_build_object('id',m.id,'name',m.name,'games',r.games,'wins',r.wins,'losses',r.losses) into favorite
 from (select case when winner=me then loser else winner end opponent,count(*) games,count(*) filter(where winner=me) wins,count(*) filter(where loser=me) losses
  from private.matches where status='confirmed' and me in(winner,loser) group by opponent) r join private.members m on m.id=r.opponent order by r.games desc,m.name,m.id limit 1;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'submitter',g.submitter,'status',g.status,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,'delta',g.delta) order by g.confirmation_order desc,g.id desc),'[]'::jsonb) into games
 from (select * from private.matches where status='confirmed' and me in(winner,loser) order by confirmation_order desc,id desc limit 10) g;
 return jsonb_build_object('me',me,'streak',jsonb_build_object('type',case when current_win is null then 'none' when current_win then 'win' else 'loss' end,'count',count_streak),'most_played_opponent',favorite,'recent_matches',games);
end; $$;
revoke all on function private.dashboard_data(text) from public,anon,authenticated;

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
      if route in ('member_house','member_action','member_history','member_summary','member_profile','member_results','member_dashboard') then actor:=private.resolve_member(token)::text;
      else
        if auth.uid() is null then raise exception 'Please sign in to continue.' using errcode='42501'; end if;
        actor:=auth.uid()::text;
      end if;
    exception when others then return private.rpc_failure(sqlerrm,sqlstate); end;
    if route in ('member_house','get_house','member_history','admin_history','member_summary','admin_summary','member_profile','admin_profile','member_results','admin_results','member_dashboard','admin_dashboard') then budget:='read';ceiling:=120;
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
      when 'member_dashboard' then return private.dashboard_data(token);
      when 'admin_dashboard' then return private.dashboard_data(null);
      when 'member_summary' then return private.summary_data(token);
      when 'admin_summary' then return private.summary_data(null);
      when 'member_profile' then return private.player_profile_data(token,params);
      when 'admin_profile' then return private.player_profile_data(null,params);
      when 'member_results' then return private.player_results_data(token,params);
      when 'admin_results' then return private.player_results_data(null,params);
      when 'member_history' then return private.history_page(token,params);
      when 'admin_history' then return private.history_page(null,params);
      when 'member_house' then return private.unlimited_member_house(token);
      when 'member_action' then return private.unlimited_member_action(token,params);
      when 'get_house' then return private.unlimited_get_house();
      when 'house_action' then return private.unlimited_house_action(params);
      else raise exception 'Unknown request.';
    end case;
  exception when others then return private.rpc_failure(sqlerrm,sqlstate); end;
end; $$;
create function public.member_dashboard(session_token text default null) returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc(case when session_token is null then 'admin_dashboard' else 'member_dashboard' end,session_token)$$;
revoke all on function public.member_dashboard(text) from public,anon,authenticated;
grant execute on function public.member_dashboard(text) to anon,authenticated;
notify pgrst,'reload schema';
