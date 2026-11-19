-- New submissions immediately enter rating order; no review is required.
-- Internal status/column names are retained for compatibility with existing history.
do $$ declare g record; ts timestamptz; begin
 perform pg_advisory_xact_lock(84201935);
 for g in select id from private.matches where status='pending' order by created,id for update loop
  ts:=clock_timestamp();
  update private.matches set status='confirmed',confirmed=ts,confirmation_order=nextval('private.confirmation_order') where id=g.id;
  insert into private.audit(action,target,created) values('auto_record',g.id,ts);
 end loop;
 perform private.recalculate();
end $$;

create or replace function private.perform_action(me uuid,uid uuid,is_admin boolean,params jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare action text:=params->>'action'; target uuid; a uuid; b uuid; nm text; member_email text; g private.matches%rowtype;
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
  select m.* from private.matches m
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

notify pgrst,'reload schema';
