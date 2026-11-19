-- Preserve the pre-void status so restoring a result reuses its original Elo order.
alter table private.matches add column status_before_void text
  check (status_before_void in ('pending','confirmed','disputed'));
update private.matches m set status_before_void=case
  when m.confirmed is not null then 'confirmed'
  when (select a.action from private.audit a where a.target=m.id
    and a.action in ('submit','confirm','dispute') order by a.id desc limit 1)='dispute' then 'disputed'
  else 'pending' end
where m.status='void';
alter table private.matches add constraint matches_void_origin_check check (
  (status='void' and status_before_void is not null) or
  (status<>'void' and status_before_void is null));

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
    insert into private.matches(id,winner,loser,submitter,submitted_by,note)
      values(target,a,b,me,uid,coalesce(params->>'note',''));
  elsif action in ('confirm','dispute','void','unvoid') then
    target:=(params->>'id')::uuid;
    select * into g from private.matches where id=target for update;
    if not found then raise exception 'Game not found.'; end if;
    if action='void' then
      if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
      if g.status='void' then raise exception 'This result has already been voided.'; end if;
      update private.matches set status_before_void=g.status,status='void' where id=target;
      perform private.recalculate();
    elsif action='unvoid' then
      if not is_admin then raise exception 'Admin access required.' using errcode='42501'; end if;
      if g.status<>'void' then raise exception 'This result is not voided.'; end if;
      update private.matches set status=g.status_before_void,status_before_void=null where id=target;
      perform private.recalculate();
    else
      if not is_admin and (me is null or (me<>g.winner and me<>g.loser) or me is not distinct from g.submitter or (uid is not null and uid is not distinct from g.submitted_by)) then
        raise exception 'Only the opponent or admin can review this result.' using errcode='42501';
      end if;
      if g.status<>'pending' and not(is_admin and g.status='disputed' and action='confirm') then raise exception 'This result has already been reviewed.'; end if;
      if action='confirm' then
        update private.matches set status='confirmed',confirmed=clock_timestamp(),confirmation_order=nextval('private.confirmation_order') where id=target;
        perform private.recalculate();
      else update private.matches set status='disputed' where id=target;
      end if;
    end if;
  else raise exception 'Unknown action.';
  end if;
  insert into private.audit(actor,member_actor,action,target) values(uid,me,action,target);
  return jsonb_build_object('ok',true);
exception when unique_violation then raise exception 'An active member with that name or email already exists.';
end; $$;
revoke all on function private.perform_action(uuid,uuid,boolean,jsonb) from public,anon,authenticated;
