-- Server-side fixed-window budgets. Apply after the earlier migrations.
-- Public RPCs retain their existing signatures. Private implementations are not exposed.
create table private.rpc_rate_limits (
  scope text not null,
  actor_hash text not null,
  window_started_at timestamptz not null,
  hits integer not null check(hits>0),
  expires_at timestamptz not null,
  primary key(scope,actor_hash)
);
create index rpc_rate_limits_expiry_idx on private.rpc_rate_limits(expires_at);
alter table private.rpc_rate_limits enable row level security;
revoke all on private.rpc_rate_limits from public,anon,authenticated;

create function private.take_rpc_budget(p_scope text,p_actor text,p_limit integer,p_seconds integer) returns integer
language plpgsql security definer set search_path='' as $$
declare ts timestamptz:=clock_timestamp(); started timestamptz; hashed text;
begin
  hashed:=encode(sha256(convert_to(coalesce(p_actor,'unknown'),'UTF8')),'hex');
  -- Expired buckets are indexed and removed on use; names and IP addresses are never stored.
  delete from private.rpc_rate_limits where expires_at<=ts;
  insert into private.rpc_rate_limits as limits(scope,actor_hash,window_started_at,hits,expires_at)
    values(p_scope,hashed,ts,1,ts+make_interval(secs=>p_seconds))
    on conflict(scope,actor_hash) do update set hits=limits.hits+1
    where limits.hits<p_limit
    returning window_started_at into started;
  if found then return 0; end if;
  select window_started_at into started from private.rpc_rate_limits where scope=p_scope and actor_hash=hashed;
  return greatest(1,ceil(extract(epoch from (started+make_interval(secs=>p_seconds)-ts)))::integer);
end; $$;
revoke all on function private.take_rpc_budget(text,text,integer,integer) from public,anon,authenticated;

create function private.rpc_failure(message text,code text,retry_seconds integer default null) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  perform set_config('response.status',case when code='RATE_LIMITED' then '429' when code='42501' then '403' else '400' end,true);
  if retry_seconds is not null then
    perform set_config('response.headers',jsonb_build_array(jsonb_build_object('Retry-After',retry_seconds::text))::text,true);
  end if;
  return jsonb_build_object('error',message,'message',message,'code',code,'retry_after_seconds',retry_seconds);
end; $$;
revoke all on function private.rpc_failure(text,text,integer) from public,anon,authenticated;

alter function public.name_sign_in(text,text) set schema private;
alter function private.name_sign_in(text,text) rename to unlimited_name_sign_in;
revoke all on function private.unlimited_name_sign_in(text,text) from public,anon,authenticated;
alter function public.member_house(text) set schema private;
alter function private.member_house(text) rename to unlimited_member_house;
revoke all on function private.unlimited_member_house(text) from public,anon,authenticated;
alter function public.member_action(text,jsonb) set schema private;
alter function private.member_action(text,jsonb) rename to unlimited_member_action;
revoke all on function private.unlimited_member_action(text,jsonb) from public,anon,authenticated;
alter function public.get_house() set schema private;
alter function private.get_house() rename to unlimited_get_house;
revoke all on function private.unlimited_get_house() from public,anon,authenticated;
alter function public.house_action(jsonb) set schema private;
alter function private.house_action(jsonb) rename to unlimited_house_action;
revoke all on function private.unlimited_house_action(jsonb) from public,anon,authenticated;

create function private.guarded_rpc(route text,token text default null,params jsonb default null,first_name text default null,last_name text default null) returns jsonb
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
      when 'name_sign_in' then return private.unlimited_name_sign_in(first_name,last_name);
      when 'member_house' then return private.unlimited_member_house(token);
      when 'member_action' then return private.unlimited_member_action(token,params);
      when 'get_house' then return private.unlimited_get_house();
      when 'house_action' then return private.unlimited_house_action(params);
      else raise exception 'Unknown request.';
    end case;
  exception when others then return private.rpc_failure(sqlerrm,sqlstate); end;
end; $$;
revoke all on function private.guarded_rpc(text,text,jsonb,text,text) from public,anon,authenticated;

create function public.name_sign_in(first_name text,last_name text) returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc('name_sign_in',null,null,first_name,last_name)$$;
create function public.member_house(session_token text) returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc('member_house',session_token)$$;
create function public.member_action(session_token text,params jsonb) returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc('member_action',session_token,params)$$;
create function public.get_house() returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc('get_house')$$;
create function public.house_action(params jsonb) returns jsonb
language sql volatile security definer set search_path='' as $$select private.guarded_rpc('house_action',null,params)$$;
revoke all on function public.name_sign_in(text,text) from public,anon,authenticated;
revoke all on function public.member_house(text) from public,anon,authenticated;
revoke all on function public.member_action(text,jsonb) from public,anon,authenticated;
revoke all on function public.get_house() from public,anon,authenticated;
revoke all on function public.house_action(jsonb) from public,anon,authenticated;
grant execute on function public.name_sign_in(text,text),public.member_house(text),public.member_action(text,jsonb) to anon,authenticated;
grant execute on function public.get_house(),public.house_action(jsonb) to authenticated;
notify pgrst,'reload schema';
