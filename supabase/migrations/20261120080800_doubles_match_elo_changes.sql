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
