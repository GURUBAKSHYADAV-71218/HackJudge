-- Freeze criteria after judging begins and prevent rounds from starting
-- without an active, claimed judge covering every participating team.

create or replace function public.prevent_scoring_config_after_round_start()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
declare
  target_event_id uuid;
  previous_event_id uuid;
begin
  target_event_id := case when tg_op = 'DELETE' then old.event_id else new.event_id end;
  if tg_op = 'UPDATE' then previous_event_id := old.event_id; end if;

  -- Serialize criteria writes against round starts.
  perform e.id from public.events e
  where e.id = any(array[target_event_id, previous_event_id])
  order by e.id for update;

  if exists (
    select 1 from public.rounds r
    where r.event_id = any(array[target_event_id, previous_event_id])
      and r.status <> 'upcoming'
  ) then
    raise exception 'Scoring criteria are locked after the first round starts';
  end if;

  if tg_op = 'UPDATE' and old.event_id is distinct from new.event_id and exists (
    select 1 from public.rounds r
    where r.event_id = old.event_id and r.status <> 'upcoming'
  ) then
    raise exception 'Scoring criteria are locked after the first round starts';
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

revoke all on function public.prevent_scoring_config_after_round_start() from public, anon, authenticated;
drop trigger if exists criteria_lock_after_round_start on public.criteria;
create trigger criteria_lock_after_round_start
  before insert or update or delete on public.criteria
  for each row execute function public.prevent_scoring_config_after_round_start();

create or replace function public.guard_round_assignment_changes_after_start()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
declare
  old_event_id uuid;
  new_event_id uuid;
  target_event_ids uuid[];
  locked_event record;
begin
  if tg_table_name = 'panel_judges' then
    if tg_op <> 'INSERT' then
      select event_id into old_event_id from public.panels where id = old.panel_id;
    end if;
    if tg_op <> 'DELETE' then
      select event_id into new_event_id from public.panels where id = new.panel_id;
    end if;
  else
    if tg_op <> 'INSERT' then old_event_id := old.event_id; end if;
    if tg_op <> 'DELETE' then new_event_id := new.event_id; end if;
  end if;
  target_event_ids := array[old_event_id, new_event_id];

  for locked_event in
    select e.id from public.events e
    where e.id = any(target_event_ids)
    order by e.id for update
  loop
    null;
  end loop;

  if tg_table_name = 'teams' and exists (
    select 1 from public.rounds r
    where r.event_id = any(target_event_ids) and r.status <> 'upcoming'
  ) then
    raise exception 'The team roster is locked after the first round starts';
  end if;
  if tg_table_name <> 'teams' and exists (
    select 1 from public.rounds r
    where r.event_id = any(target_event_ids) and r.status <> 'upcoming'
  ) then
    raise exception 'Judge assignments are locked after the first round starts';
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.guard_round_assignment_changes_after_start() from public, anon, authenticated;

drop trigger if exists teams_lock_after_round_start on public.teams;
create trigger teams_lock_after_round_start
  before insert or update or delete on public.teams
  for each row execute function public.guard_round_assignment_changes_after_start();
drop trigger if exists panels_lock_after_round_start on public.panels;
create trigger panels_lock_after_round_start
  before insert or update or delete on public.panels
  for each row execute function public.guard_round_assignment_changes_after_start();
drop trigger if exists panel_judges_lock_after_round_start on public.panel_judges;
create trigger panel_judges_lock_after_round_start
  before insert or update or delete on public.panel_judges
  for each row execute function public.guard_round_assignment_changes_after_start();
drop trigger if exists judge_assignments_lock_after_round_start on public.judges;
create trigger judge_assignments_lock_after_round_start
  before insert or update of event_id, round_ids, email on public.judges
  for each row execute function public.guard_round_assignment_changes_after_start();

create or replace function public.start_event_round(target_event_id uuid, target_round_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
declare
  event_state public.event_status;
  round_state public.round_status;
begin
  select status into event_state
  from public.events
  where id = target_event_id and organizer_id = auth.uid()
  for update;
  if not found then raise exception 'Event not found or access denied'; end if;
  if event_state = 'closed' then raise exception 'Closed events cannot start a round'; end if;
  if exists (select 1 from public.rounds where event_id = target_event_id and status = 'live') then
    raise exception 'Close the active round before starting another';
  end if;

  select status into round_state
  from public.rounds
  where id = target_round_id and event_id = target_event_id
  for update;
  if not found or round_state <> 'upcoming' then raise exception 'Round is not available to start'; end if;
  if target_round_id <> (
    select id from public.rounds where event_id = target_event_id and status = 'upcoming'
    order by order_index limit 1
  ) then
    raise exception 'Rounds must start in their configured order';
  end if;
  if exists (
    select 1 from public.rounds r
    where r.event_id = target_event_id
      and r.order_index < (select order_index from public.rounds where id = target_round_id)
      and r.status <> 'closed'
  ) then
    raise exception 'Close and shortlist each prior round before continuing';
  end if;
  if exists (
    select 1 from public.rounds previous_round
    where previous_round.event_id = target_event_id
      and previous_round.order_index = (
        select max(r.order_index) from public.rounds r
        where r.event_id = target_event_id
          and r.order_index < (select order_index from public.rounds where id = target_round_id)
      )
      and previous_round.advanced_team_ids is null
  ) then
    raise exception 'Finalize the previous round shortlist before continuing';
  end if;

  if not exists (select 1 from public.criteria c where c.event_id = target_event_id and c.archived_at is null)
     or not exists (select 1 from public.teams t where t.event_id = target_event_id)
     or not exists (select 1 from public.judges j where j.event_id = target_event_id) then
    raise exception 'A round requires at least one active criterion, team, and judge';
  end if;

  if not exists (
    select 1 from public.criteria c
    where c.event_id = target_event_id and c.archived_at is null
      and (cardinality(c.round_ids) = 0 or target_round_id = any(c.round_ids))
  ) then
    raise exception 'The round requires at least one active scoring criterion';
  end if;

  if exists (
    select 1 from public.teams t
    where t.event_id = target_event_id
      and (
        (select order_index from public.rounds where id = target_round_id) =
          (select min(order_index) from public.rounds where event_id = target_event_id)
        or exists (
          select 1 from public.rounds previous_round
          where previous_round.event_id = target_event_id
            and previous_round.order_index = (
              select max(r.order_index) from public.rounds r
              where r.event_id = target_event_id
                and r.order_index < (select order_index from public.rounds where id = target_round_id)
            )
            and previous_round.advanced_team_ids is not null
            and t.id = any(previous_round.advanced_team_ids)
        )
      )
      and not exists (
        select 1 from public.judges j
        where j.event_id = target_event_id
          and j.status = 'active'
          and j.user_id is not null
          and (cardinality(j.round_ids) = 0 or target_round_id = any(j.round_ids))
          and (
            t.track_id is null
            or exists (
              select 1 from public.panel_judges pj
              join public.panels p on p.id = pj.panel_id
              where pj.judge_id = j.id
                and p.event_id = target_event_id
                and p.track_id = t.track_id
            )
          )
      )
  ) then
    raise exception 'Every team must have at least one judge assigned to its track and round';
  end if;

  update public.rounds set status = 'live' where id = target_round_id;
  if event_state = 'draft' then
    update public.events set status = 'live' where id = target_event_id;
  end if;
end;
$$;

revoke all on function public.start_event_round(uuid, uuid) from public, anon;
grant execute on function public.start_event_round(uuid, uuid) to authenticated;
