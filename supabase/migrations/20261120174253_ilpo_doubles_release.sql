select pg_advisory_xact_lock(84201935);
create temporary table ilpo_doubles_before on commit drop as
select id,rating,wins,losses,delta from private.members;
-- Keep the original winner/loser as the first member of each side.
alter table private.matches
 add column winner_partner uuid references private.members(id),
 add column loser_partner uuid references private.members(id),
 add column ladder_results jsonb,
 add constraint match_distinct_teams check (
  (winner_partner is null and loser_partner is null) or
  (winner_partner is not null and loser_partner is not null and
   winner_partner <> loser_partner and winner_partner not in (winner,loser) and loser_partner not in (winner,loser))
 );
alter table private.members add column format_stats jsonb not null default '{}'::jsonb;

create function private.elo_change(winner_rating double precision,loser_rating double precision,k integer)
returns double precision language sql immutable strict set search_path='' as $$
 select k*(1-1/(1+power(10.0,(loser_rating-winner_rating)/400.0)))
$$;
revoke all on function private.elo_change(double precision,double precision,integer) from public,anon,authenticated;

create or replace function private.recalculate() returns void
language plpgsql security definer set search_path='' as $$
declare g private.matches%rowtype; mode text; format text; winners uuid[]; losers uuid[];
 player_id uuid; player_rating double precision; a double precision; b double precision;
 change double precision; step double precision; won boolean; snapshot jsonb; results jsonb;
begin
 perform pg_advisory_xact_lock(84201935);
 update private.members set rating=1000,wins=0,losses=0,delta=0,format_stats='{}' where id is not null;
 update private.matches set delta=null,winner_after=null,loser_after=null,ladder_results=null where id is not null;
 for g in select * from private.matches where status='confirmed' order by confirmation_order,id loop
  winners:=array_remove(array[g.winner,g.winner_partner],null);
  losers:=array_remove(array[g.loser,g.loser_partner],null);
  format:=case when g.winner_partner is null then 'singles' else 'doubles' end;
  results:='{}';
  foreach mode in array array['overall',format] loop
   select avg(case when mode='overall' then rating else coalesce((format_stats->mode->>'rating')::double precision,1000) end)
    into a from private.members where id=any(winners);
   select avg(case when mode='overall' then rating else coalesce((format_stats->mode->>'rating')::double precision,1000) end)
    into b from private.members where id=any(losers);
   change:=private.elo_change(a,b,case when mode='overall' and format='doubles' then 16 else 32 end);
   snapshot:='{}';
   foreach player_id in array winners||losers loop
    won:=player_id=any(winners);
    step:=case when won then change else -change end;
    if mode='overall' then
      update private.members set rating=rating+step,wins=wins+won::int,losses=losses+(not won)::int,delta=step
       where id=player_id returning rating into player_rating;
    else
      update private.members set format_stats=jsonb_set(format_stats,array[mode],jsonb_build_object(
        'rating',coalesce((format_stats->mode->>'rating')::double precision,1000)+step,
        'wins',coalesce((format_stats->mode->>'wins')::int,0)+won::int,
        'losses',coalesce((format_stats->mode->>'losses')::int,0)+(not won)::int,'delta',step))
       where id=player_id returning (format_stats->mode->>'rating')::double precision into player_rating;
    end if;
    snapshot:=snapshot||jsonb_build_object(player_id::text,jsonb_build_object('rating',player_rating,'delta',step));
   end loop;
   results:=results||jsonb_build_object(mode,snapshot);
  end loop;
  update private.matches set ladder_results=results,
    delta=(results->'overall'->g.winner::text->>'delta')::double precision,
    winner_after=(results->'overall'->g.winner::text->>'rating')::double precision,
    loser_after=(results->'overall'->g.loser::text->>'rating')::double precision where id=g.id;
 end loop;
end; $$;
revoke all on function private.recalculate() from public,anon,authenticated;
select private.recalculate();

create or replace function private.perform_action(me uuid,uid uuid,is_admin boolean,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare action text:=params->>'action'; target uuid; a uuid; b uuid; ap uuid; bp uuid; participants uuid[]; nm text; member_email text; g private.matches%rowtype; new_note text; new_date timestamptz;
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
    ap:=(params->>'winner_partner')::uuid; bp:=(params->>'loser_partner')::uuid;
    if target is null or (ap is null)<>(bp is null) then raise exception 'Select both teammates for doubles.'; end if;
    participants:=array_remove(array[a,b,ap,bp],null);
    if cardinality(participants)<>(case when ap is null then 2 else 4 end)
      or (select count(*) from private.members where id=any(participants) and active)<>cardinality(participants) then
      raise exception 'Select different active players for each slot.';
    end if;
    if not is_admin and (me is null or not(me=any(participants))) then raise exception 'You can only submit your own games.' using errcode='42501'; end if;
    if length(coalesce(params->>'note',''))>240 then raise exception 'Notes must be 240 characters or fewer.'; end if;
    select * into g from private.matches where id=target;
    if found then
      if ((uid is not null and g.submitted_by=uid) or (uid is null and g.submitted_by is null and g.submitter=me)) and g.winner=a and g.loser=b and g.winner_partner is not distinct from ap and g.loser_partner is not distinct from bp and g.note=coalesce(params->>'note','') then return jsonb_build_object('ok',true); end if;
      raise exception 'Match ID already used.';
    end if;
    insert into private.matches(id,winner,loser,winner_partner,loser_partner,submitter,submitted_by,note,status,confirmed,confirmation_order)
      values(target,a,b,ap,bp,me,uid,coalesce(params->>'note',''),'confirmed',clock_timestamp(),nextval('private.confirmation_order'));
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

create or replace function private.summary_data(session_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb; players jsonb; games jsonb; totals jsonb; revision text;
begin
 context:=private.read_context(session_token);
 select coalesce(max(id),0)::text into revision from private.audit;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'email',case when (context->>'admin')::boolean then m.email else null end,
  'active',m.active,'rating',m.rating,'wins',m.wins,'losses',m.losses,'delta',m.delta) order by m.rating desc,m.name,m.id),'[]'::jsonb) into players from private.members m;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,'submitter',g.submitter,'status',g.status,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,'delta',g.delta) order by g.created desc,g.id),'[]'::jsonb) into games
 from (select * from private.matches where status in ('disputed','void') union all (select * from private.matches where status='confirmed' order by created desc,id limit 3)) g;
 select jsonb_build_object('recorded',count(*) filter(where status='confirmed'),'disputed',count(*) filter(where status='disputed'),'voided',count(*) filter(where status='void')) into totals from private.matches;
 return context||jsonb_build_object('players',players,'matches',games,'match_counts',totals,'revision',revision,
  'pin_required',not(context->>'admin')::boolean and exists(select 1 from private.members where id=(context->>'me')::uuid and pin_hash is null),
  'rank_baselines',jsonb_build_object('day',private.rankings_at(now()-interval '24 hours'),'week',private.rankings_at(now()-interval '7 days'),'month',private.rankings_at(now()-interval '30 days')));
end; $$;
revoke all on function private.summary_data(text) from public,anon,authenticated;

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
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,'submitter',g.submitter,'status',g.status,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,'delta',g.delta) order by g.created desc,g.id),'[]'::jsonb) into games
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
  select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,
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

create or replace function private.ladder_rankings_at(cutoff timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare initial jsonb; ratings jsonb; sheet jsonb; mode text; format text; g record; a double precision; b double precision;
 change double precision; result jsonb:='{}'; ranked_list jsonb; player_id uuid; winners uuid[]; losers uuid[];
begin
 select coalesce(jsonb_object_agg(id::text,1000),'{}'::jsonb) into initial from private.members;
 ratings:=jsonb_build_object('overall',initial,'singles',initial,'doubles',initial);
 for g in
  select m.* from (
   select original.id,
    case when edit.before_result is null then original.winner else (edit.before_result->>'winner')::uuid end winner,
    case when edit.before_result is null then original.loser else (edit.before_result->>'loser')::uuid end loser,
    case when edit.before_result is null then original.winner_partner else (edit.before_result->>'winner_partner')::uuid end winner_partner,
    case when edit.before_result is null then original.loser_partner else (edit.before_result->>'loser_partner')::uuid end loser_partner,
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
  winners:=array_remove(array[g.winner,g.winner_partner],null);
  losers:=array_remove(array[g.loser,g.loser_partner],null);
  format:=case when g.winner_partner is null then 'singles' else 'doubles' end;
  foreach mode in array array['overall',format] loop
   sheet:=ratings->mode;
   select avg((sheet->>id::text)::double precision) into a from unnest(winners) u(id);
   select avg((sheet->>id::text)::double precision) into b from unnest(losers) u(id);
   change:=private.elo_change(a,b,case when mode='overall' and format='doubles' then 16 else 32 end);
   foreach player_id in array winners||losers loop
    sheet:=jsonb_set(sheet,array[player_id::text],to_jsonb((sheet->>player_id::text)::double precision+
      case when player_id=any(winners) then change else -change end));
   end loop;
   ratings:=jsonb_set(ratings,array[mode],sheet);
  end loop;
 end loop;
 foreach mode in array array['overall','singles','doubles'] loop
  sheet:=ratings->mode;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'rank',rank,'rating',rating) order by rank),'[]') into ranked_list from (
   select id,(sheet->>id::text)::double precision rating,row_number() over(order by (sheet->>id::text)::double precision desc,name,id) rank
   from private.members where active and joined_at<=cutoff
  ) ranked;
  result:=result||jsonb_build_object(mode,ranked_list);
 end loop;
 return result;
end; $$;
revoke all on function private.ladder_rankings_at(timestamptz) from public,anon,authenticated;
create or replace function private.rankings_at(cutoff timestamptz) returns jsonb
language sql security definer set search_path='' as $$select private.ladder_rankings_at(cutoff)->'overall'$$;

create or replace function private.summary_data(session_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb; players jsonb; games jsonb; totals jsonb; revision text; by_format jsonb; recent_by_format jsonb; day jsonb; week jsonb; month jsonb;
begin
 context:=private.read_context(session_token);
 day:=private.ladder_rankings_at(now()-interval '24 hours');
 week:=private.ladder_rankings_at(now()-interval '7 days');
 month:=private.ladder_rankings_at(now()-interval '30 days');
 select coalesce(max(id),0)::text into revision from private.audit;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'email',case when (context->>'admin')::boolean then m.email else null end,
  'active',m.active,'format_stats',m.format_stats,'rating',m.rating,'wins',m.wins,'losses',m.losses,'delta',m.delta) order by m.rating desc,m.name,m.id),'[]'::jsonb) into players from private.members m;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,'submitter',g.submitter,'status',g.status,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,'delta',g.delta) order by g.created desc,g.id),'[]'::jsonb) into games
 from (select * from private.matches where status in ('disputed','void') union all (select * from private.matches where status='confirmed' order by created desc,id limit 3)) g;
 select jsonb_build_object('recorded',count(*) filter(where status='confirmed'),'disputed',count(*) filter(where status='disputed'),'voided',count(*) filter(where status='void')) into totals from private.matches;
 select jsonb_build_object('singles',count(*) filter(where winner_partner is null),'doubles',count(*) filter(where winner_partner is not null))
  into by_format from private.matches where status='confirmed';
 select jsonb_object_agg(mode,recent) into recent_by_format from (
  select mode,(select coalesce(jsonb_agg(jsonb_build_object(
    'id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,
    'status',g.status,'created',g.created,'played_at',g.played_at,'note',g.note,
    'delta',g.ladder_results->mode->g.winner::text->'delta') order by g.created desc,g.id),'[]')
   from (select * from private.matches where status='confirmed' and (winner_partner is not null)=(mode='doubles') order by created desc,id limit 3) g) recent
  from (values('singles'),('doubles')) modes(mode)
 ) formats;
 return context||jsonb_build_object('players',players,'matches',games,'match_counts',totals,'revision',revision,
  'pin_required',not(context->>'admin')::boolean and exists(select 1 from private.members where id=(context->>'me')::uuid and pin_hash is null),
  'doubles_enabled',true,'format_match_counts',by_format,'format_recent_matches',recent_by_format,
  'rank_baselines',jsonb_build_object('day',day->'overall','week',week->'overall','month',month->'overall'),
  'format_baselines',jsonb_build_object(
    'singles',jsonb_build_object('day',day->'singles','week',week->'singles','month',month->'singles'),
    'doubles',jsonb_build_object('day',day->'doubles','week',week->'doubles','month',month->'doubles')));
end; $$;
revoke all on function private.summary_data(text) from public,anon,authenticated;

-- Keep read models private. Only the existing identity-checked RPCs return their rows.
create view private.rated_participation with (security_invoker=true) as
 select g.id,g.winner,g.loser,g.winner_partner,g.loser_partner,g.created,g.played_at,g.confirmed,g.confirmation_order,g.note,g.ladder_results,
  sides.person,sides.won,sides.opponents,case when g.winner_partner is null then 'singles' else 'doubles' end as format
 from private.matches g
 cross join lateral (values
  (g.winner,true,array_remove(array[g.loser,g.loser_partner],null)),
  (g.winner_partner,true,array_remove(array[g.loser,g.loser_partner],null)),
  (g.loser,false,array_remove(array[g.winner,g.winner_partner],null)),
  (g.loser_partner,false,array_remove(array[g.winner,g.winner_partner],null))
 ) sides(person,won,opponents)
 where g.status='confirmed' and sides.person is not null;
revoke all on private.rated_participation from public,anon,authenticated;

create function private.ladder_mode(params jsonb) returns text language plpgsql immutable set search_path='' as $$
declare mode text:=coalesce(params->>'ladder','overall');
begin
 if mode not in ('overall','singles','doubles') then raise exception 'Choose Overall, Singles, or Doubles.'; end if;
 return mode;
end; $$;
revoke all on function private.ladder_mode(jsonb) from public,anon,authenticated;

create or replace function private.player_results_data(session_token text,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person_id uuid:=(params->>'player_id')::uuid; requested integer:=coalesce((params->>'page')::integer,1); actual integer; total integer; games jsonb; mode text:=private.ladder_mode(params);
begin
 perform private.read_context(session_token);
 if not exists(select 1 from private.members where id=person_id) then raise exception 'Player not found.'; end if;
 if requested<1 then raise exception 'Page must be at least 1.'; end if;
 select count(*) into total from private.rated_participation where person=person_id and (mode='overall' or format=mode);
 actual:=least(requested,greatest(1,(total+9)/10));
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,
  'opponent',(select string_agg(m.name,' & ' order by u.slot) from unnest(g.opponents) with ordinality u(id,slot) join private.members m on m.id=u.id),
  'format',g.format,'won',g.won,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,
  'rating',g.ladder_results->mode->person_id::text->'rating','delta',g.ladder_results->mode->person_id::text->'delta') order by g.confirmation_order desc,g.id desc),'[]') into games
 from (select * from private.rated_participation where person=person_id and (mode='overall' or format=mode)
       order by confirmation_order desc,id desc limit 10 offset (actual-1)*10) g;
 return jsonb_build_object('matches',games,'total',total,'page',actual,'page_size',10);
end; $$;

create or replace function private.player_profile_data(session_token text,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb; person_id uuid:=(params->>'player_id')::uuid; p private.members%rowtype; chart_range text:=coalesce(params->>'chart_range','recent');
 mode text:=private.ladder_mode(params); total integer; starting_game integer; starting_rating double precision:=1000; points jsonb; h2h jsonb; matchup jsonb; me uuid; stats jsonb;
begin
 context:=private.read_context(session_token); me:=(context->>'me')::uuid;
 select * into p from private.members where id=person_id;
 if not found then raise exception 'Player not found.'; end if;
 if chart_range not in ('recent','all') then raise exception 'Choose recent or all-time history.'; end if;
 stats:=case when mode='overall' then jsonb_build_object('rating',p.rating,'wins',p.wins,'losses',p.losses,'delta',p.delta)
  else coalesce(p.format_stats->mode,'{"rating":1000,"wins":0,"losses":0,"delta":0}') end;
 select count(*) into total from private.rated_participation where person=person_id and (mode='overall' or format=mode);
 starting_game:=case when chart_range='recent' then greatest(0,total-50) else 0 end;
 if starting_game>0 then
  select (ladder_results->mode->person_id::text->>'rating')::double precision into starting_rating from private.rated_participation
   where person=person_id and (mode='overall' or format=mode) order by confirmation_order desc,id desc offset 50 limit 1;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'rating',g.ladder_results->mode->person_id::text->'rating',
  'delta',g.ladder_results->mode->person_id::text->'delta','confirmed',g.confirmed) order by g.confirmation_order,g.id),'[]') into points
 from (select * from private.rated_participation where person=person_id and (mode='overall' or format=mode)
  order by confirmation_order desc,id desc limit case when chart_range='recent' then 50 else null end) g;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'wins',r.wins,'losses',r.losses) order by m.name,m.id),'[]') into h2h
 from (select opponent,count(*) filter(where won) wins,count(*) filter(where not won) losses
  from private.rated_participation cross join lateral unnest(opponents) o(opponent)
  where person=person_id and (mode='overall' or format=mode) group by opponent) r join private.members m on m.id=r.opponent;
 if me is not null and me<>person_id then
  select jsonb_build_object('wins',count(*) filter(where won),'losses',count(*) filter(where not won)) into matchup
   from private.rated_participation where person=me and person_id=any(opponents) and (mode='overall' or format=mode);
 end if;
 return jsonb_build_object('player',jsonb_build_object('id',p.id,'name',p.name,'active',p.active)||stats,
  'chart',jsonb_build_object('range',chart_range,'history',points,'starting_rating',starting_rating,'start_game',starting_game,'total_games',total),
  'head_to_head',h2h,'your_head_to_head',matchup,'results',private.player_results_data(session_token,params||jsonb_build_object('page',1)));
end; $$;

drop function public.player_profile(uuid,text,text);
drop function public.player_results(uuid,text,integer);
create function public.player_profile(player_id uuid,session_token text default null,chart_range text default 'recent',ladder text default 'overall') returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc(case when session_token is null then 'admin_profile' else 'member_profile' end,session_token,jsonb_build_object('player_id',player_id,'chart_range',chart_range,'ladder',ladder))$$;
create function public.player_results(player_id uuid,session_token text default null,page integer default 1,ladder text default 'overall') returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc(case when session_token is null then 'admin_results' else 'member_results' end,session_token,jsonb_build_object('player_id',player_id,'page',page,'ladder',ladder))$$;
revoke all on function public.player_profile(uuid,text,text,text),public.player_results(uuid,text,integer,text) from public,anon,authenticated;
grant execute on function public.player_profile(uuid,text,text,text),public.player_results(uuid,text,integer,text) to anon,authenticated;
notify pgrst,'reload schema';

create or replace function private.dashboard_data(session_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb; me uuid; games jsonb; favorite jsonb; current_win boolean; count_streak integer:=0; entry record;
begin
 context:=private.read_context(session_token); me:=(context->>'me')::uuid;
 if me is null then raise exception 'This account has no linked player.' using errcode='42501'; end if;
 for entry in select won from private.rated_participation where person=me order by confirmation_order desc,id desc loop
  if current_win is null then current_win:=entry.won; end if;
  exit when entry.won<>current_win;
  count_streak:=count_streak+1;
 end loop;
 select jsonb_build_object('id',m.id,'name',m.name,'games',r.games,'wins',r.wins,'losses',r.losses) into favorite
 from (select opponent,count(*) games,count(*) filter(where won) wins,count(*) filter(where not won) losses
  from private.rated_participation cross join lateral unnest(opponents) o(opponent) where person=me group by opponent) r join private.members m on m.id=r.opponent order by r.games desc,m.name,m.id limit 1;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,'submitter',g.submitter,'status',g.status,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,'delta',g.delta) order by g.confirmation_order desc,g.id desc),'[]'::jsonb) into games
 from (select * from private.matches where status='confirmed' and me in(winner,loser,winner_partner,loser_partner) order by confirmation_order desc,id desc limit 10) g;
 return jsonb_build_object('me',me,'streak',jsonb_build_object('type',case when current_win is null then 'none' when current_win then 'win' else 'loss' end,'count',count_streak),'most_played_opponent',favorite,'recent_matches',games);
end; $$;
revoke all on function private.dashboard_data(text) from public,anon,authenticated;

create or replace function private.perform_action(me uuid,uid uuid,is_admin boolean,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare action text:=params->>'action'; target uuid; a uuid; b uuid; ap uuid; bp uuid; participants uuid[]; nm text; member_email text; g private.matches%rowtype; new_note text; new_date timestamptz;
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
    ap:=(params->>'winner_partner')::uuid; bp:=(params->>'loser_partner')::uuid;
    if target is null or (ap is null)<>(bp is null) then raise exception 'Select both teammates for doubles.'; end if;
    participants:=array_remove(array[a,b,ap,bp],null);
    if cardinality(participants)<>(case when ap is null then 2 else 4 end)
      or (select count(*) from private.members where id=any(participants) and active)<>cardinality(participants) then
      raise exception 'Select different active players for each slot.';
    end if;
    if not is_admin and (me is null or not(me=any(participants))) then raise exception 'You can only submit your own games.' using errcode='42501'; end if;
    if length(coalesce(params->>'note',''))>240 then raise exception 'Notes must be 240 characters or fewer.'; end if;
    select * into g from private.matches where id=target;
    if found then
      if ((uid is not null and g.submitted_by=uid) or (uid is null and g.submitted_by is null and g.submitter=me)) and g.winner=a and g.loser=b and g.winner_partner is not distinct from ap and g.loser_partner is not distinct from bp and g.note=coalesce(params->>'note','') then return jsonb_build_object('ok',true); end if;
      raise exception 'Match ID already used.';
    end if;
    insert into private.matches(id,winner,loser,winner_partner,loser_partner,submitter,submitted_by,note,status,confirmed,confirmation_order)
      values(target,a,b,ap,bp,me,uid,coalesce(params->>'note',''),'confirmed',clock_timestamp(),nextval('private.confirmation_order'));
    perform private.recalculate();
  elsif action='edit_result' then
    if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
    target:=(params->>'id')::uuid;
    select * into g from private.matches where id=target for update;
    if not found then raise exception 'Game not found.'; end if;
    a:=coalesce((params->>'winner')::uuid,g.winner); b:=coalesce((params->>'loser')::uuid,g.loser);
    if g.winner_partner is null then
      if params->>'winner_partner' is not null or params->>'loser_partner' is not null then raise exception 'The match format cannot change.'; end if;
      if a=b then raise exception 'Select two different players.'; end if;
      ap:=null; bp:=null;
    else
      ap:=coalesce((params->>'winner_partner')::uuid,g.winner_partner);
      bp:=coalesce((params->>'loser_partner')::uuid,g.loser_partner);
    end if;
    participants:=array_remove(array[a,b,ap,bp],null);
    if (select count(distinct id) from unnest(participants) u(id))<>cardinality(participants) then
      raise exception 'Select four different players.';
    end if;
    if (select count(*) from private.members where id=any(participants)
      and (active or id in(g.winner,g.loser,g.winner_partner,g.loser_partner)))<>cardinality(participants) then
      raise exception 'Select active players or keep the original players.';
    end if;
    new_note:=case when params ? 'note' then coalesce(params->>'note','') else g.note end;
    if length(new_note)>240 then raise exception 'Notes must be 240 characters or fewer.'; end if;
    begin new_date:=coalesce(nullif(params->>'played_at','')::timestamptz,g.played_at);
    exception when invalid_datetime_format or datetime_field_overflow then raise exception 'Enter a valid match date.'; end;
    if not isfinite(new_date) or new_date>clock_timestamp()+interval '5 minutes' then raise exception 'The match date cannot be in the future.'; end if;
    update private.matches set winner=a,loser=b,winner_partner=ap,loser_partner=bp,note=new_note,played_at=new_date where id=target;
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
      if not is_admin and (me is null or not(me=any(array_remove(array[g.winner,g.loser,g.winner_partner,g.loser_partner],null)))) then raise exception 'Only a player in this game or an admin can dispute it.' using errcode='42501'; end if;
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

-- Aggregate rated matches played on the same team, independently of head-to-head.
create or replace function private.player_profile_data(session_token text,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb; person_id uuid:=(params->>'player_id')::uuid; p private.members%rowtype; chart_range text:=coalesce(params->>'chart_range','recent');
 mode text:=private.ladder_mode(params); total integer; starting_game integer; starting_rating double precision:=1000; points jsonb; h2h jsonb; matchup jsonb; me uuid; stats jsonb; partners jsonb;
begin
 context:=private.read_context(session_token); me:=(context->>'me')::uuid;
 select * into p from private.members where id=person_id;
 if not found then raise exception 'Player not found.'; end if;
 if chart_range not in ('recent','all') then raise exception 'Choose recent or all-time history.'; end if;
 stats:=case when mode='overall' then jsonb_build_object('rating',p.rating,'wins',p.wins,'losses',p.losses,'delta',p.delta)
  else coalesce(p.format_stats->mode,'{"rating":1000,"wins":0,"losses":0,"delta":0}') end;
 select count(*) into total from private.rated_participation where person=person_id and (mode='overall' or format=mode);
 starting_game:=case when chart_range='recent' then greatest(0,total-50) else 0 end;
 if starting_game>0 then
  select (ladder_results->mode->person_id::text->>'rating')::double precision into starting_rating from private.rated_participation
   where person=person_id and (mode='overall' or format=mode) order by confirmation_order desc,id desc offset 50 limit 1;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'rating',g.ladder_results->mode->person_id::text->'rating',
  'delta',g.ladder_results->mode->person_id::text->'delta','confirmed',g.confirmed) order by g.confirmation_order,g.id),'[]') into points
 from (select * from private.rated_participation where person=person_id and (mode='overall' or format=mode)
  order by confirmation_order desc,id desc limit case when chart_range='recent' then 50 else null end) g;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'wins',r.wins,'losses',r.losses) order by m.name,m.id),'[]') into h2h
 from (select opponent,count(*) filter(where won) wins,count(*) filter(where not won) losses
  from private.rated_participation cross join lateral unnest(opponents) o(opponent)
  where person=person_id and (mode='overall' or format=mode) group by opponent) r join private.members m on m.id=r.opponent;
 if me is not null and me<>person_id then
  select jsonb_build_object('wins',count(*) filter(where won),'losses',count(*) filter(where not won)) into matchup
   from private.rated_participation where person=me and person_id=any(opponents) and (mode='overall' or format=mode);
 end if;
 if mode='doubles' then
  select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'wins',r.wins,'losses',r.losses)
    order by r.wins+r.losses desc,m.name,m.id),'[]') into partners
  from (
   select case when person=winner then winner_partner when person=winner_partner then winner
               when person=loser then loser_partner else loser end as teammate,
    count(*) filter(where won) wins,count(*) filter(where not won) losses
   from private.rated_participation where person=person_id and format='doubles'
   group by teammate
  ) r join private.members m on m.id=r.teammate;
 end if;
 return jsonb_build_object('player',jsonb_build_object('id',p.id,'name',p.name,'active',p.active)||stats,
  'chart',jsonb_build_object('range',chart_range,'history',points,'starting_rating',starting_rating,'start_game',starting_game,'total_games',total),
  'head_to_head',h2h,'your_head_to_head',matchup,'results',private.player_results_data(session_token,params||jsonb_build_object('page',1)))
  || case when mode='doubles' then jsonb_build_object('partners',partners) else '{}'::jsonb end;
end; $$;


-- Expose each ladder’s recorded changes on result rows without sending the rating snapshots.
create or replace function private.summary_data(session_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb; players jsonb; games jsonb; totals jsonb; revision text; by_format jsonb; recent_by_format jsonb; day jsonb; week jsonb; month jsonb;
begin
 context:=private.read_context(session_token);
 day:=private.ladder_rankings_at(now()-interval '24 hours');
 week:=private.ladder_rankings_at(now()-interval '7 days');
 month:=private.ladder_rankings_at(now()-interval '30 days');
 select coalesce(max(id),0)::text into revision from private.audit;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'email',case when (context->>'admin')::boolean then m.email else null end,
  'active',m.active,'format_stats',m.format_stats,'rating',m.rating,'wins',m.wins,'losses',m.losses,'delta',m.delta) order by m.rating desc,m.name,m.id),'[]'::jsonb) into players from private.members m;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,'submitter',g.submitter,'status',g.status,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,'delta',g.delta,'overall_delta',g.delta,'doubles_delta',g.ladder_results->'doubles'->g.winner::text->'delta') order by g.created desc,g.id),'[]'::jsonb) into games
 from (select * from private.matches where status in ('disputed','void') union all (select * from private.matches where status='confirmed' order by created desc,id limit 3)) g;
 select jsonb_build_object('recorded',count(*) filter(where status='confirmed'),'disputed',count(*) filter(where status='disputed'),'voided',count(*) filter(where status='void')) into totals from private.matches;
 select jsonb_build_object('singles',count(*) filter(where winner_partner is null),'doubles',count(*) filter(where winner_partner is not null))
  into by_format from private.matches where status='confirmed';
 select jsonb_object_agg(mode,recent) into recent_by_format from (
  select mode,(select coalesce(jsonb_agg(jsonb_build_object(
    'id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,
    'status',g.status,'created',g.created,'played_at',g.played_at,'note',g.note,
    'delta',g.ladder_results->mode->g.winner::text->'delta','overall_delta',g.delta,'doubles_delta',g.ladder_results->'doubles'->g.winner::text->'delta') order by g.created desc,g.id),'[]')
   from (select * from private.matches where status='confirmed' and (winner_partner is not null)=(mode='doubles') order by created desc,id limit 3) g) recent
  from (values('singles'),('doubles')) modes(mode)
 ) formats;
 return context||jsonb_build_object('players',players,'matches',games,'match_counts',totals,'revision',revision,
  'pin_required',not(context->>'admin')::boolean and exists(select 1 from private.members where id=(context->>'me')::uuid and pin_hash is null),
  'doubles_enabled',true,'format_match_counts',by_format,'format_recent_matches',recent_by_format,
  'rank_baselines',jsonb_build_object('day',day->'overall','week',week->'overall','month',month->'overall'),
  'format_baselines',jsonb_build_object(
    'singles',jsonb_build_object('day',day->'singles','week',week->'singles','month',month->'singles'),
    'doubles',jsonb_build_object('day',day->'doubles','week',week->'doubles','month',month->'doubles')));
end; $$;

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
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,'submitter',g.submitter,'status',g.status,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,'delta',g.delta,'overall_delta',g.delta,'doubles_delta',g.ladder_results->'doubles'->g.winner::text->'delta') order by g.created desc,g.id),'[]'::jsonb) into games
 from (select * from private.matches where status='confirmed' order by created desc,id limit 10 offset (actual-1)*10) g;
 return jsonb_build_object('matches',games,'total',total,'page',actual,'page_size',10);
end; $$;

create or replace function private.dashboard_data(session_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb; me uuid; games jsonb; favorite jsonb; current_win boolean; count_streak integer:=0; entry record;
begin
 context:=private.read_context(session_token); me:=(context->>'me')::uuid;
 if me is null then raise exception 'This account has no linked player.' using errcode='42501'; end if;
 for entry in select won from private.rated_participation where person=me order by confirmation_order desc,id desc loop
  if current_win is null then current_win:=entry.won; end if;
  exit when entry.won<>current_win;
  count_streak:=count_streak+1;
 end loop;
 select jsonb_build_object('id',m.id,'name',m.name,'games',r.games,'wins',r.wins,'losses',r.losses) into favorite
 from (select opponent,count(*) games,count(*) filter(where won) wins,count(*) filter(where not won) losses
  from private.rated_participation cross join lateral unnest(opponents) o(opponent) where person=me group by opponent) r join private.members m on m.id=r.opponent order by r.games desc,m.name,m.id limit 1;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,'submitter',g.submitter,'status',g.status,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,'delta',g.delta,'overall_delta',g.delta,'doubles_delta',g.ladder_results->'doubles'->g.winner::text->'delta') order by g.confirmation_order desc,g.id desc),'[]'::jsonb) into games
 from (select * from private.matches where status='confirmed' and me in(winner,loser,winner_partner,loser_partner) order by confirmation_order desc,id desc limit 10) g;
 return jsonb_build_object('me',me,'streak',jsonb_build_object('type',case when current_win is null then 'none' when current_win then 'win' else 'loss' end,'count',count_streak),'most_played_opponent',favorite,'recent_matches',games);
end; $$;

create or replace function private.player_results_data(session_token text,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person_id uuid:=(params->>'player_id')::uuid; requested integer:=coalesce((params->>'page')::integer,1); actual integer; total integer; games jsonb; mode text:=private.ladder_mode(params);
begin
 perform private.read_context(session_token);
 if not exists(select 1 from private.members where id=person_id) then raise exception 'Player not found.'; end if;
 if requested<1 then raise exception 'Page must be at least 1.'; end if;
 select count(*) into total from private.rated_participation where person=person_id and (mode='overall' or format=mode);
 actual:=least(requested,greatest(1,(total+9)/10));
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'winner_partner',g.winner_partner,'loser_partner',g.loser_partner,
  'opponent',(select string_agg(m.name,' & ' order by u.slot) from unnest(g.opponents) with ordinality u(id,slot) join private.members m on m.id=u.id),
  'format',g.format,'won',g.won,'created',g.created,'played_at',g.played_at,'confirmed',g.confirmed,'note',g.note,
  'rating',g.ladder_results->mode->person_id::text->'rating','delta',g.ladder_results->mode->person_id::text->'delta',
  'overall_delta',g.ladder_results->'overall'->person_id::text->'delta',
  'doubles_delta',g.ladder_results->'doubles'->person_id::text->'delta') order by g.confirmation_order desc,g.id desc),'[]') into games
 from (select * from private.rated_participation where person=person_id and (mode='overall' or format=mode)
       order by confirmation_order desc,id desc limit 10 offset (actual-1)*10) g;
 return jsonb_build_object('matches',games,'total',total,'page',actual,'page_size',10);
end; $$;

do $verify_preservation$
begin
 if exists (
  select 1 from pg_temp.ilpo_doubles_before b full join private.members m using(id)
  where b.id is null or m.id is null or
   (b.rating,b.wins,b.losses,b.delta) is distinct from (m.rating,m.wins,m.losses,m.delta)
 ) then raise exception 'Existing standings changed during the doubles migration'; end if;
end;
$verify_preservation$;
