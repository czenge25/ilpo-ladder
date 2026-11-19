-- Additive endpoints: existing main clients keep their original house/profile payloads.
create index matches_winner_rating_idx on private.matches(winner,confirmation_order desc,id desc) where status='confirmed';
create index matches_loser_rating_idx on private.matches(loser,confirmation_order desc,id desc) where status='confirmed';
create function private.read_context(session_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare me uuid; em text; admin boolean:=false;
begin
 if session_token is not null then me:=private.resolve_member(session_token);
 else
  select lower(email) into em from auth.users where id=auth.uid() and email_confirmed_at is not null;
  if em is null then raise exception 'Please sign in to continue.' using errcode='42501'; end if;
  select exists(select 1 from private.admins where user_id=auth.uid()) into admin;
  select id into me from private.members where email=em and active;
  if not admin and me is null then raise exception 'Active membership required.' using errcode='42501'; end if;
 end if;
 return jsonb_build_object('me',me,'admin',admin,'email',em);
end; $$;
revoke all on function private.read_context(text) from public,anon,authenticated;

create function private.summary_data(session_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb; players jsonb; games jsonb; totals jsonb; revision text;
begin
 context:=private.read_context(session_token);
 select coalesce(max(id),0)::text into revision from private.audit;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'email',case when (context->>'admin')::boolean then m.email else null end,
  'active',m.active,'rating',m.rating,'wins',m.wins,'losses',m.losses,'delta',m.delta) order by m.rating desc,m.name,m.id),'[]'::jsonb) into players from private.members m;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'submitter',g.submitter,'status',g.status,'created',g.created,'confirmed',g.confirmed,'note',g.note,'delta',g.delta) order by g.created desc,g.id),'[]'::jsonb) into games
 from (select * from private.matches where status in ('disputed','void') union all (select * from private.matches where status='confirmed' order by created desc,id limit 3)) g;
 select jsonb_build_object('recorded',count(*) filter(where status='confirmed'),'disputed',count(*) filter(where status='disputed'),'voided',count(*) filter(where status='void')) into totals from private.matches;
 return context||jsonb_build_object('players',players,'matches',games,'match_counts',totals,'revision',revision,
  'pin_required',not(context->>'admin')::boolean and exists(select 1 from private.members where id=(context->>'me')::uuid and pin_hash is null),
  'rank_baselines',jsonb_build_object('day',private.rankings_at(now()-interval '24 hours'),'week',private.rankings_at(now()-interval '7 days'),'month',private.rankings_at(now()-interval '30 days')));
end; $$;
revoke all on function private.summary_data(text) from public,anon,authenticated;

create function private.player_results_data(session_token text,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare person uuid:=(params->>'player_id')::uuid; requested integer:=coalesce((params->>'page')::integer,1); actual integer; total integer; games jsonb;
begin
 perform private.read_context(session_token);
 if not exists(select 1 from private.members where id=person) then raise exception 'Player not found.'; end if;
 if requested<1 then raise exception 'Page must be at least 1.'; end if;
 select count(*) into total from private.matches where status='confirmed' and person in(winner,loser);
 actual:=least(requested,greatest(1,(total+9)/10));
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'opponent',m.name,'won',g.winner=person,'created',g.created,'confirmed',g.confirmed,'note',g.note,
  'rating',case when g.winner=person then g.winner_after else g.loser_after end,'delta',case when g.winner=person then g.delta else -g.delta end) order by g.confirmation_order desc,g.id desc),'[]'::jsonb) into games
 from (select * from private.matches where status='confirmed' and person in(winner,loser) order by confirmation_order desc,id desc limit 10 offset (actual-1)*10) g
 join private.members m on m.id=case when g.winner=person then g.loser else g.winner end;
 return jsonb_build_object('matches',games,'total',total,'page',actual,'page_size',10);
end; $$;
revoke all on function private.player_results_data(text,jsonb) from public,anon,authenticated;

create function private.player_profile_data(session_token text,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare context jsonb; person uuid:=(params->>'player_id')::uuid; p private.members%rowtype; chart_range text:=coalesce(params->>'chart_range','recent'); total integer; starting_game integer; starting_rating double precision:=1000; points jsonb; h2h jsonb; matchup jsonb; me uuid;
begin
 context:=private.read_context(session_token); me:=(context->>'me')::uuid;
 select * into p from private.members where id=person;
 if not found then raise exception 'Player not found.'; end if;
 if chart_range not in ('recent','all') then raise exception 'Choose recent or all-time history.'; end if;
 select count(*) into total from private.matches where status='confirmed' and person in(winner,loser);
 starting_game:=case when chart_range='recent' then greatest(0,total-50) else 0 end;
 if starting_game>0 then
  select case when winner=person then winner_after else loser_after end into starting_rating from private.matches
   where status='confirmed' and person in(winner,loser) order by confirmation_order desc,id desc offset 50 limit 1;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'rating',case when g.winner=person then g.winner_after else g.loser_after end,
  'delta',case when g.winner=person then g.delta else -g.delta end,'confirmed',g.confirmed) order by g.confirmation_order,g.id),'[]'::jsonb) into points
 from (select * from private.matches where status='confirmed' and person in(winner,loser) order by confirmation_order desc,id desc limit case when chart_range='recent' then 50 else null end) g;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'wins',r.wins,'losses',r.losses) order by m.name,m.id),'[]'::jsonb) into h2h
 from (select case when winner=person then loser else winner end opponent,count(*) filter(where winner=person) wins,count(*) filter(where loser=person) losses from private.matches where status='confirmed' and person in(winner,loser) group by opponent) r join private.members m on m.id=r.opponent;
 if me is not null and me<>person then
  select jsonb_build_object('wins',count(*) filter(where winner=me),'losses',count(*) filter(where loser=me)) into matchup from private.matches where status='confirmed' and ((winner=me and loser=person) or (winner=person and loser=me));
 end if;
 return jsonb_build_object('player',jsonb_build_object('id',p.id,'name',p.name,'active',p.active,'rating',p.rating,'wins',p.wins,'losses',p.losses,'delta',p.delta),
  'chart',jsonb_build_object('range',chart_range,'history',points,'starting_rating',starting_rating,'start_game',starting_game,'total_games',total),
  'head_to_head',h2h,'your_head_to_head',matchup,'results',private.player_results_data(session_token,jsonb_build_object('player_id',person,'page',1)));
end; $$;
revoke all on function private.player_profile_data(text,jsonb) from public,anon,authenticated;

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
      if route in ('member_house','member_action','member_history','member_summary','member_profile','member_results') then actor:=private.resolve_member(token)::text;
      else
        if auth.uid() is null then raise exception 'Please sign in to continue.' using errcode='42501'; end if;
        actor:=auth.uid()::text;
      end if;
    exception when others then return private.rpc_failure(sqlerrm,sqlstate); end;
    if route in ('member_house','get_house','member_history','admin_history','member_summary','admin_summary','member_profile','admin_profile','member_results','admin_results') then budget:='read';ceiling:=120;
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
create function public.ladder_summary(session_token text default null) returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc(case when session_token is null then 'admin_summary' else 'member_summary' end,session_token)$$;
create function public.player_profile(player_id uuid,session_token text default null,chart_range text default 'recent') returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc(case when session_token is null then 'admin_profile' else 'member_profile' end,session_token,jsonb_build_object('player_id',player_id,'chart_range',chart_range))$$;
create function public.player_results(player_id uuid,session_token text default null,page integer default 1) returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc(case when session_token is null then 'admin_results' else 'member_results' end,session_token,jsonb_build_object('player_id',player_id,'page',page))$$;
revoke all on function public.ladder_summary(text),public.player_profile(uuid,text,text),public.player_results(uuid,text,integer) from public,anon,authenticated;
grant execute on function public.ladder_summary(text),public.player_profile(uuid,text,text),public.player_results(uuid,text,integer) to anon,authenticated;
notify pgrst,'reload schema';
