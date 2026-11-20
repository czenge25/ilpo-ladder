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
