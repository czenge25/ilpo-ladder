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

