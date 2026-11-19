-- Fetch older recorded matches only when their history page is opened.
create index matches_recorded_created_idx on private.matches(created desc,id desc) where status='confirmed';
create function private.history_page(session_token text,params jsonb) returns jsonb
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
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'winner',g.winner,'loser',g.loser,'submitter',g.submitter,'status',g.status,'created',g.created,'confirmed',g.confirmed,'note',g.note,'delta',g.delta) order by g.created desc,g.id),'[]'::jsonb) into games
 from (select * from private.matches where status='confirmed' order by created desc,id limit 10 offset (actual-1)*10) g;
 return jsonb_build_object('matches',games,'total',total,'page',actual,'page_size',10);
end; $$;
revoke all on function private.history_page(text,jsonb) from public,anon,authenticated;

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
      if route in ('member_house','member_action','member_history') then actor:=private.resolve_member(token)::text;
      else
        if auth.uid() is null then raise exception 'Please sign in to continue.' using errcode='42501'; end if;
        actor:=auth.uid()::text;
      end if;
    exception when others then return private.rpc_failure(sqlerrm,sqlstate); end;
    if route in ('member_house','get_house','member_history','admin_history') then budget:='read';ceiling:=120;
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
create function public.match_history(session_token text default null,page integer default 1) returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc(case when session_token is null then 'admin_history' else 'member_history' end,session_token,jsonb_build_object('page',page))$$;
revoke all on function public.match_history(text,integer) from public,anon,authenticated;
grant execute on function public.match_history(text,integer) to anon,authenticated;

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
    'submitter',g.submitter,'status',g.status,'created',g.created,'confirmed',g.confirmed,'note',g.note,'delta',g.delta)
    order by g.created desc,g.id),'[]'::jsonb) into games from (select * from private.matches where status in ('disputed','void')
    union all (select * from private.matches where status='confirmed' order by created desc,id limit 3)) g;
  select jsonb_build_object('recorded',count(*) filter(where status='confirmed'),'disputed',count(*) filter(where status='disputed'),'voided',count(*) filter(where status='void')) into totals from private.matches;
  select coalesce(jsonb_agg(jsonb_build_object('winner',winner,'loser',loser,'wins',wins)),'[]'::jsonb) into h2h from (select winner,loser,count(*) wins from private.matches where status='confirmed' group by winner,loser) results;
  return jsonb_build_object('admin',is_admin,'me',me,'email',em,'players',players,'matches',games,'match_counts',totals,'head_to_head',h2h,
    'pin_required',not is_admin and exists(select 1 from private.members where id=me and pin_hash is null),
    'rank_baselines',jsonb_build_object('day',private.rankings_at(now()-interval '24 hours'),'week',private.rankings_at(now()-interval '7 days'),'month',private.rankings_at(now()-interval '30 days')));
end; $$;
revoke all on function private.house_data(uuid,boolean,text) from public,anon,authenticated;

notify pgrst,'reload schema';
