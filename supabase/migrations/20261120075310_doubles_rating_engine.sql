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
