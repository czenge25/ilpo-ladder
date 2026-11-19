-- Explicit predicates preserve full Elo replay while respecting the API safe-update guard.
create or replace function private.recalculate() returns void
language plpgsql security definer set search_path = '' as $$
declare g record; a double precision; b double precision; change double precision;
begin
  update private.members set rating=1000,wins=0,losses=0,delta=0 where id is not null;
  update private.matches set delta=null,winner_after=null,loser_after=null where id is not null;
  for g in select * from private.matches where status='confirmed' order by confirmation_order,id loop
    select rating into a from private.members where id=g.winner;
    select rating into b from private.members where id=g.loser;
    change:=32*(1-1/(1+power(10.0,(b-a)/400.0)));
    update private.members set rating=a+change,wins=wins+1,delta=change where id=g.winner;
    update private.members set rating=b-change,losses=losses+1,delta=-change where id=g.loser;
    update private.matches set delta=change,winner_after=a+change,loser_after=b-change where id=g.id;
  end loop;
end; $$;
