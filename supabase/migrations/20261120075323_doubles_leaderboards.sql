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
