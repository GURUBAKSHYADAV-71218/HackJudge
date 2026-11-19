-- Security hardening for databases created from the previous hackjudge-schema.sql.
-- Apply this migration before deploying the corresponding frontend changes.

alter table public.scores
  add column if not exists revision bigint generated always as identity;

create unique index if not exists scores_revision_unique on public.scores(revision);

-- The same-event override foreign key below depends on round_id. Add it before
-- attempting to create that constraint so legacy schemas can apply this file.
alter table public.overrides
  add column if not exists round_id uuid references public.rounds(id) on delete cascade;

do $$
begin
  if exists (select 1 from public.rounds group by event_id, order_index having count(*) > 1) then
    raise exception 'Resolve duplicate round order indexes before applying security hardening';
  end if;
  if exists (
    select 1 from public.panel_judges pj
    join public.panels p on p.id = pj.panel_id
    join public.judges j on j.id = pj.judge_id
    where p.event_id <> j.event_id
  ) then
    raise exception 'Resolve cross-event judge panel assignments before applying security hardening';
  end if;
  if exists (
    select 1 from public.panels p join public.tracks t on t.id = p.track_id where p.event_id <> t.event_id
  ) or exists (
    select 1 from public.teams t join public.tracks tr on tr.id = t.track_id where t.event_id <> tr.event_id
  ) then
    raise exception 'Resolve cross-event track references before applying security hardening';
  end if;
  if exists (
    select 1 from public.events e join public.criteria c on c.id = e.tiebreak_criterion_id where e.id <> c.event_id
  ) then
    raise exception 'Resolve cross-event tie-break criteria before applying security hardening';
  end if;
end;
$$;

create unique index if not exists idx_rounds_event_id_id_unique on public.rounds(event_id, id);
create unique index if not exists idx_rounds_event_order_unique on public.rounds(event_id, order_index);
create unique index if not exists idx_criteria_event_id_id_unique on public.criteria(event_id, id);
create unique index if not exists idx_tracks_event_id_id_unique on public.tracks(event_id, id);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'events_tiebreak_criterion_same_event_fk') then
    alter table public.events add constraint events_tiebreak_criterion_same_event_fk
      foreign key (id, tiebreak_criterion_id) references public.criteria(event_id, id)
      on delete set null (tiebreak_criterion_id) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'panels_track_same_event_fk') then
    alter table public.panels add constraint panels_track_same_event_fk
      foreign key (event_id, track_id) references public.tracks(event_id, id) on delete restrict not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'teams_track_same_event_fk') then
    alter table public.teams add constraint teams_track_same_event_fk
      foreign key (event_id, track_id) references public.tracks(event_id, id) on delete restrict not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'overrides_round_same_event_fk') then
    alter table public.overrides add constraint overrides_round_same_event_fk
      foreign key (event_id, round_id) references public.rounds(event_id, id) on delete cascade not valid;
  end if;
end;
$$;

do $$
begin
  if exists (
    select 1 from public.rounds where status = 'live' group by event_id having count(*) > 1
  ) then
    raise exception 'Resolve events with multiple live rounds before applying security hardening';
  end if;
end;
$$;
create unique index if not exists idx_rounds_one_live_per_event
  on public.rounds(event_id) where status = 'live';

alter table public.overrides
  add column if not exists amount numeric(5,2) not null default 0;

do $$
declare
  item record;
begin
  for item in select * from (values
    ('events', 'events_name_length', 'char_length(btrim(name)) between 1 and 120'),
    ('events', 'events_date_order', 'start_date is null or end_date is null or start_date <= end_date'),
    ('rounds', 'rounds_name_length', 'char_length(btrim(name)) between 1 and 80'),
    ('rounds', 'rounds_order_nonnegative', 'order_index >= 0'),
    ('rounds', 'rounds_advance_count_nonnegative', 'advance_count is null or advance_count >= 0'),
    ('criteria', 'criteria_name_length', 'char_length(btrim(name)) between 1 and 40'),
    ('criteria', 'criteria_weight_range', 'weight between 0 and 100'),
    ('criteria', 'criteria_max_score_range', 'max_score > 0 and max_score <= 100'),
    ('criteria', 'criteria_order_nonnegative', 'order_index >= 0'),
    ('tracks', 'tracks_name_length', 'char_length(btrim(name)) between 1 and 40'),
    ('panels', 'panels_name_length', 'char_length(btrim(name)) between 1 and 60'),
    ('teams', 'teams_name_length', 'char_length(btrim(name)) between 1 and 60'),
    ('teams', 'teams_members_array', 'jsonb_typeof(members) = ''array'''),
    ('judges', 'judges_name_length', 'char_length(btrim(name)) between 1 and 80'),
    ('judges', 'judges_email_length', 'email is null or char_length(email) <= 120')
  ) as checks(table_name, constraint_name, expression)
  loop
    if not exists (select 1 from pg_constraint where conname = item.constraint_name) then
      execute format('alter table public.%I add constraint %I check (%s) not valid',
        item.table_name, item.constraint_name, item.expression);
    end if;
  end loop;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'overrides_amount_range') then
    alter table public.overrides
      add constraint overrides_amount_range check (amount between -10 and 10);
  end if;
end;
$$;

update public.judges
set token_expires_at = now() + interval '30 days'
where token_expires_at is null;
alter table public.judges
  alter column token_expires_at set default (now() + interval '30 days');

create or replace function public.is_organizer_of_event(check_event_id uuid)
returns boolean language sql security definer stable set search_path = pg_catalog, public, auth, pg_temp as $$
  select exists (
    select 1 from public.events
    where id = check_event_id and organizer_id = auth.uid()
  );
$$;

create or replace function public.is_current_judge(check_judge_id uuid)
returns boolean language sql security definer stable set search_path = pg_catalog, public, auth, pg_temp as $$
  select check_judge_id = public.jwt_judge_id()
      or exists (select 1 from public.judges where id = check_judge_id and user_id = auth.uid());
$$;

create or replace function public.can_judge_access_team(target_judge_id uuid, target_team_id uuid)
returns boolean language sql security definer stable set search_path = pg_catalog, public, auth, pg_temp as $$
  select exists (
    select 1
    from public.judges j
    join public.teams t on t.id = target_team_id and t.event_id = j.event_id
    join public.events e on e.id = j.event_id and e.status = 'live'
    join public.rounds current_round on current_round.event_id = j.event_id and current_round.status = 'live'
    where j.id = target_judge_id
      and j.status = 'active'
      and (target_judge_id = public.jwt_judge_id() or j.user_id = auth.uid())
      and (cardinality(j.round_ids) = 0 or current_round.id = any(j.round_ids))
      and (
        t.track_id is null
        or exists (
          select 1 from public.panel_judges pj
          join public.panels p on p.id = pj.panel_id
          where pj.judge_id = j.id and p.track_id = t.track_id
        )
      )
      and (
        current_round.order_index = (select min(r.order_index) from public.rounds r where r.event_id = j.event_id)
        or exists (
          select 1 from public.rounds previous_round
          where previous_round.event_id = j.event_id
            and previous_round.order_index = (
              select max(r.order_index) from public.rounds r
              where r.event_id = j.event_id and r.order_index < current_round.order_index
            )
            and previous_round.advanced_team_ids is not null
            and target_team_id = any(previous_round.advanced_team_ids)
        )
      )
  );
$$;
revoke all on function public.can_judge_access_team(uuid, uuid) from public, anon;
grant execute on function public.can_judge_access_team(uuid, uuid) to authenticated;

create or replace function public.current_user_email_verified()
returns boolean language sql security definer stable set search_path = pg_catalog, public, auth, pg_temp as $$
  select coalesce((select email_confirmed_at is not null from auth.users where id = auth.uid()), false);
$$;

create or replace function public.claim_judge_row(target_judge_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
begin
  if auth.uid() is null or not public.current_user_email_verified() then
    raise exception 'A verified signed-in email is required to claim a judge invitation';
  end if;

  update public.judges
  set user_id = auth.uid(), status = 'active'
  where id = target_judge_id
    and user_id is null
    and lower(email) = lower(auth.jwt() ->> 'email');

  if not found then
    raise exception 'No matching unclaimed judge row for this verified email';
  end if;
end;
$$;

revoke all on function public.claim_judge_row(uuid) from public, anon;
grant execute on function public.claim_judge_row(uuid) to authenticated;

create or replace function public.can_submit_score(
  target_judge_id uuid,
  target_team_id uuid,
  target_round_id uuid,
  target_criterion_id uuid,
  score_value numeric
)
returns boolean language sql security definer stable set search_path = pg_catalog, public, auth, pg_temp as $$
  select exists (
    select 1
    from public.judges j
    join public.teams t on t.id = target_team_id and t.event_id = j.event_id
    join public.rounds r on r.id = target_round_id and r.event_id = j.event_id
    join public.criteria c on c.id = target_criterion_id and c.event_id = j.event_id
    join public.events e on e.id = j.event_id
    where j.id = target_judge_id
      and (target_judge_id = public.jwt_judge_id() or j.user_id = auth.uid())
      and j.status = 'active'
      and e.status = 'live'
      and r.status = 'live'
      and c.archived_at is null
      and score_value >= 0
      and score_value <= c.max_score
      and (cardinality(c.round_ids) = 0 or target_round_id = any(c.round_ids))
      and (cardinality(j.round_ids) = 0 or target_round_id = any(j.round_ids))
      and (
        r.order_index = (select min(first_round.order_index) from public.rounds first_round where first_round.event_id = j.event_id)
        or exists (
          select 1 from public.rounds previous_round
          where previous_round.event_id = j.event_id
            and previous_round.order_index = (
              select max(prior_round.order_index) from public.rounds prior_round
              where prior_round.event_id = j.event_id and prior_round.order_index < r.order_index
            )
            and previous_round.advanced_team_ids is not null
            and target_team_id = any(previous_round.advanced_team_ids)
        )
      )
      and (
        t.track_id is null
        or exists (
          select 1 from public.panel_judges pj
          join public.panels p on p.id = pj.panel_id
          where pj.judge_id = j.id and p.track_id = t.track_id
        )
      )
  );
$$;

revoke all on function public.can_submit_score(uuid, uuid, uuid, uuid, numeric) from public, anon;
grant execute on function public.can_submit_score(uuid, uuid, uuid, uuid, numeric) to authenticated;

create or replace function public.consume_judge_invite(invite_token_value text)
returns table(id uuid, event_id uuid, name text, round_ids uuid[], event_status public.event_status)
language sql security definer set search_path = pg_catalog, public, extensions, auth, pg_temp as $$
  update public.judges j
  set invite_token = encode(extensions.gen_random_bytes(18), 'hex'),
      token_expires_at = now() + interval '30 days',
      status = 'active'
  from public.events e
  where j.invite_token = invite_token_value
    and j.token_expires_at > now()
    and e.id = j.event_id
    and e.status = 'live'
  returning j.id, j.event_id, j.name, j.round_ids, e.status;
$$;

revoke all on function public.consume_judge_invite(text) from public, anon, authenticated;
grant execute on function public.consume_judge_invite(text) to service_role;

create or replace function public.start_event_round(target_event_id uuid, target_round_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
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
  if exists (select 1 from public.rounds where event_id = target_event_id and order_index < (
    select order_index from public.rounds where id = target_round_id
  ) and status <> 'closed') then
    raise exception 'Close and shortlist each prior round before continuing';
  end if;
  if exists (select 1 from public.rounds where event_id = target_event_id and order_index < (
    select order_index from public.rounds where id = target_round_id
  ) and order_index = (select max(order_index) from public.rounds where event_id = target_event_id and order_index < (
    select order_index from public.rounds where id = target_round_id
  )) and advanced_team_ids is null) then
    raise exception 'Finalize the previous round shortlist before continuing';
  end if;
  if not exists (select 1 from public.criteria where event_id = target_event_id and archived_at is null)
     or not exists (select 1 from public.teams where event_id = target_event_id)
     or not exists (select 1 from public.judges where event_id = target_event_id) then
    raise exception 'A round requires at least one active criterion, team, and judge';
  end if;

  update public.rounds set status = 'live' where id = target_round_id;
  if event_state = 'draft' then
    update public.events set status = 'live' where id = target_event_id;
  end if;
end;
$$;

create or replace function public.close_event_round(target_event_id uuid, target_round_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
begin
  perform 1 from public.events
  where id = target_event_id and organizer_id = auth.uid() and status = 'live'
  for update;
  if not found then raise exception 'Live event not found or access denied'; end if;

  update public.rounds set status = 'closed'
  where id = target_round_id and event_id = target_event_id and status = 'live';
  if not found then raise exception 'Round is not live'; end if;
end;
$$;

create or replace function public.finalize_event_shortlist(
  target_event_id uuid,
  target_round_id uuid,
  selected_team_ids uuid[]
)
returns void language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
begin
  perform 1 from public.events
  where id = target_event_id and organizer_id = auth.uid() and status = 'live'
  for update;
  if not found then raise exception 'Event not found or access denied'; end if;
  if selected_team_ids is null or cardinality(selected_team_ids) = 0 then
    raise exception 'Select at least one team to advance';
  end if;
  if cardinality(selected_team_ids) <> (select count(distinct id) from unnest(selected_team_ids) as ids(id)) then
    raise exception 'Duplicate teams are not allowed';
  end if;
  if (select count(*) from public.teams where event_id = target_event_id and id = any(selected_team_ids)) <> cardinality(selected_team_ids) then
    raise exception 'All selected teams must belong to this event';
  end if;

  update public.rounds
  set advance_count = cardinality(selected_team_ids),
      advanced_team_ids = selected_team_ids,
      status = 'closed'
  where id = target_round_id and event_id = target_event_id and status in ('live', 'closed');
  if not found then raise exception 'Round must be live or closed to finalize advancement'; end if;
end;
$$;

create or replace function public.reorder_event_rounds(target_event_id uuid, ordered_round_ids uuid[])
returns void language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
begin
  perform 1 from public.events
  where id = target_event_id and organizer_id = auth.uid() and status = 'draft'
  for update;
  if not found then raise exception 'Only the owner of a draft event can reorder rounds'; end if;
  if ordered_round_ids is null or cardinality(ordered_round_ids) = 0
     or cardinality(ordered_round_ids) <> (select count(distinct id) from unnest(ordered_round_ids) as ids(id))
     or cardinality(ordered_round_ids) <> (select count(*) from public.rounds where event_id = target_event_id)
     or (select count(*) from public.rounds where event_id = target_event_id and id = any(ordered_round_ids)) <> cardinality(ordered_round_ids) then
    raise exception 'Round order must include every event round exactly once';
  end if;
  if exists (select 1 from public.rounds where event_id = target_event_id and status <> 'upcoming') then
    raise exception 'Rounds can only be reordered before the event starts';
  end if;

  update public.rounds r
  set order_index = ordered.position::integer - 1
  from unnest(ordered_round_ids) with ordinality as ordered(id, position)
  where r.id = ordered.id and r.event_id = target_event_id;
end;
$$;

revoke all on function public.start_event_round(uuid, uuid) from public, anon;
revoke all on function public.close_event_round(uuid, uuid) from public, anon;
revoke all on function public.finalize_event_shortlist(uuid, uuid, uuid[]) from public, anon;
revoke all on function public.reorder_event_rounds(uuid, uuid[]) from public, anon;
grant execute on function public.start_event_round(uuid, uuid) to authenticated;
grant execute on function public.close_event_round(uuid, uuid) to authenticated;
grant execute on function public.finalize_event_shortlist(uuid, uuid, uuid[]) to authenticated;
grant execute on function public.reorder_event_rounds(uuid, uuid[]) to authenticated;

create or replace function public.delete_event(target_event_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
begin
  if not exists (select 1 from public.events where id = target_event_id and organizer_id = auth.uid()) then
    raise exception 'Event not found or access denied';
  end if;

  delete from public.scores s using public.rounds r
    where s.round_id = r.id and r.event_id = target_event_id;
  delete from public.overrides where event_id = target_event_id;
  delete from public.panel_judges pj using public.panels p
    where pj.panel_id = p.id and p.event_id = target_event_id;
  delete from public.teams where event_id = target_event_id;
  delete from public.judges where event_id = target_event_id;
  delete from public.panels where event_id = target_event_id;
  delete from public.tracks where event_id = target_event_id;
  delete from public.criteria where event_id = target_event_id;
  delete from public.rounds where event_id = target_event_id;
  delete from public.events where id = target_event_id;
end;
$$;

revoke all on function public.delete_event(uuid) from public, anon;
grant execute on function public.delete_event(uuid) to authenticated;

create or replace function public.guard_event_status_transition()
returns trigger language plpgsql set search_path = pg_catalog, public, auth, pg_temp as $$
begin
  if new.status = old.status then return new; end if;
  if old.status = 'draft' and new.status = 'live'
     and exists (select 1 from public.rounds where event_id = new.id and status = 'live') then
    return new;
  end if;
  if old.status = 'live' and new.status = 'closed'
     and not exists (select 1 from public.rounds where event_id = new.id and status = 'live') then
    return new;
  end if;
  raise exception 'Invalid event status transition';
end;
$$;

drop trigger if exists guard_event_status_transition_before_update on public.events;
create trigger guard_event_status_transition_before_update
  before update of status on public.events
  for each row execute function public.guard_event_status_transition();

create or replace function public.enforce_event_collection_limit()
returns trigger language plpgsql set search_path = pg_catalog, public, auth, pg_temp as $$
declare
  maximum_rows integer;
  existing_rows integer;
begin
  perform 1 from public.events where id = new.event_id for update;
  if not found then raise exception 'Event not found'; end if;

  case tg_table_name
    when 'teams' then maximum_rows := 200; select count(*) into existing_rows from public.teams where event_id = new.event_id;
    when 'judges' then maximum_rows := 50; select count(*) into existing_rows from public.judges where event_id = new.event_id;
    when 'tracks' then maximum_rows := 20; select count(*) into existing_rows from public.tracks where event_id = new.event_id;
    when 'panels' then maximum_rows := 20; select count(*) into existing_rows from public.panels where event_id = new.event_id;
    when 'rounds' then maximum_rows := 5; select count(*) into existing_rows from public.rounds where event_id = new.event_id;
    when 'criteria' then maximum_rows := 10; select count(*) into existing_rows from public.criteria where event_id = new.event_id;
    else raise exception 'Unsupported event collection';
  end case;

  if existing_rows >= maximum_rows then
    raise exception 'This event has reached the maximum of % %', maximum_rows, tg_table_name;
  end if;
  return new;
end;
$$;

drop trigger if exists limit_event_teams on public.teams;
drop trigger if exists limit_event_judges on public.judges;
drop trigger if exists limit_event_tracks on public.tracks;
drop trigger if exists limit_event_panels on public.panels;
drop trigger if exists limit_event_rounds on public.rounds;
drop trigger if exists limit_event_criteria on public.criteria;
create trigger limit_event_teams before insert on public.teams for each row execute function public.enforce_event_collection_limit();
create trigger limit_event_judges before insert on public.judges for each row execute function public.enforce_event_collection_limit();
create trigger limit_event_tracks before insert on public.tracks for each row execute function public.enforce_event_collection_limit();
create trigger limit_event_panels before insert on public.panels for each row execute function public.enforce_event_collection_limit();
create trigger limit_event_rounds before insert on public.rounds for each row execute function public.enforce_event_collection_limit();
create trigger limit_event_criteria before insert on public.criteria for each row execute function public.enforce_event_collection_limit();

create or replace function public.validate_panel_judge_same_event()
returns trigger language plpgsql set search_path = pg_catalog, public, auth, pg_temp as $$
declare
  panel_event_id uuid;
  judge_event_id uuid;
begin
  select event_id into panel_event_id from public.panels where id = new.panel_id;
  select event_id into judge_event_id from public.judges where id = new.judge_id;
  if panel_event_id is null or judge_event_id is null or panel_event_id <> judge_event_id then
    raise exception 'Panel and judge must belong to the same event';
  end if;
  return new;
end;
$$;

drop trigger if exists panel_judges_same_event_before_write on public.panel_judges;
create trigger panel_judges_same_event_before_write
  before insert or update on public.panel_judges
  for each row execute function public.validate_panel_judge_same_event();

create or replace function public.create_event_setup(
  new_event_id uuid,
  event_name text,
  event_kind public.event_type,
  round_data jsonb,
  criteria_data jsonb
)
returns uuid language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
declare
  round_count integer;
  criterion_count integer;
begin
  if auth.uid() is null or not exists (select 1 from public.organizers where id = auth.uid()) then
    raise exception 'A signed-in organizer profile is required';
  end if;
  if round_data is null or jsonb_typeof(round_data) <> 'array'
     or criteria_data is null or jsonb_typeof(criteria_data) <> 'array' then
    raise exception 'Rounds and criteria must be arrays';
  end if;

  round_count := jsonb_array_length(round_data);
  criterion_count := jsonb_array_length(criteria_data);
  if round_count < 1 or round_count > 5 or criterion_count < 1 or criterion_count > 10 then
    raise exception 'Event must contain 1–5 rounds and 1–10 criteria';
  end if;
  if (select coalesce(sum((item ->> 'weight')::numeric), 0) from jsonb_array_elements(criteria_data) as rows(item)) <> 100 then
    raise exception 'Criterion weights must sum to 100';
  end if;

  insert into public.events(id, organizer_id, name, event_type, status)
  values (new_event_id, auth.uid(), btrim(event_name), event_kind, 'draft');

  insert into public.rounds(id, event_id, name, order_index, status)
  select (item ->> 'id')::uuid, new_event_id, btrim(item ->> 'name'), position::integer - 1, 'upcoming'
  from jsonb_array_elements(round_data) with ordinality as rows(item, position);

  insert into public.criteria(id, event_id, name, weight, max_score, round_ids, order_index)
  select (item ->> 'id')::uuid,
         new_event_id,
         btrim(item ->> 'name'),
         (item ->> 'weight')::numeric,
         (item ->> 'max_score')::numeric,
         array(select jsonb_array_elements_text(coalesce(item -> 'round_ids', '[]'::jsonb))::uuid),
         coalesce((item ->> 'order_index')::integer, position::integer - 1)
  from jsonb_array_elements(criteria_data) with ordinality as rows(item, position);

  if exists (
    select 1 from public.criteria c
    where c.event_id = new_event_id
      and exists (select 1 from unnest(c.round_ids) as selected(selected_round_id) where not exists (
        select 1 from public.rounds r where r.id = selected.selected_round_id and r.event_id = new_event_id
      ))
  ) then
    raise exception 'Criteria reference a round outside this event';
  end if;

  return new_event_id;
end;
$$;

revoke all on function public.create_event_setup(uuid, text, public.event_type, jsonb, jsonb) from public, anon;
grant execute on function public.create_event_setup(uuid, text, public.event_type, jsonb, jsonb) to authenticated;

create or replace function public.stamp_score_revision()
returns trigger language plpgsql set search_path = public as $$
begin
  new.client_submitted_at := clock_timestamp();
  new.synced_at := clock_timestamp();
  return new;
end;
$$;

drop trigger if exists stamp_score_revision_before_insert on public.scores;
create trigger stamp_score_revision_before_insert
  before insert on public.scores
  for each row execute function public.stamp_score_revision();

drop policy if exists "public reads non-draft events" on public.events;
drop policy if exists "public reads rounds of non-draft events" on public.rounds;
drop policy if exists "public reads criteria of non-draft events" on public.criteria;
drop policy if exists "public reads teams of non-draft events" on public.teams;
drop policy if exists "public reads tracks of non-draft events" on public.tracks;
drop policy if exists "public reads panels of non-draft events" on public.panels;
drop policy if exists "judge inserts own scores for assigned rounds" on public.scores;
drop policy if exists "auth user can see unclaimed judge rows for their email" on public.judges;
drop policy if exists "auth user can see unclaimed judge rows for their verified email" on public.judges;

drop policy if exists "assigned judge reads event" on public.events;
drop policy if exists "organizer full access to own events" on public.events;
drop policy if exists "organizer reads own events" on public.events;
drop policy if exists "organizer creates draft events" on public.events;
drop policy if exists "organizer updates own event settings" on public.events;
drop policy if exists "organizer deletes own events" on public.events;
create policy "organizer reads own events" on public.events
  for select using (organizer_id = auth.uid());
create policy "organizer creates draft events" on public.events
  for insert with check (organizer_id = auth.uid() and status = 'draft');
create policy "organizer updates own event settings" on public.events
  for update using (organizer_id = auth.uid()) with check (organizer_id = auth.uid());
create policy "organizer deletes own events" on public.events
  for delete using (organizer_id = auth.uid());
create policy "assigned judge reads event" on public.events
  for select using (exists (select 1 from public.judges j where j.event_id = events.id and public.is_current_judge(j.id)));

drop policy if exists "organizer full access to own rounds" on public.rounds;
drop policy if exists "organizer reads own rounds" on public.rounds;
drop policy if exists "organizer inserts upcoming rounds" on public.rounds;
create policy "organizer reads own rounds" on public.rounds
  for select using (public.is_organizer_of_event(event_id));
create policy "organizer inserts upcoming rounds" on public.rounds
  for insert with check (public.is_organizer_of_event(event_id) and status = 'upcoming');

drop policy if exists "assigned judge reads event rounds" on public.rounds;
create policy "assigned judge reads event rounds" on public.rounds
  for select using (exists (select 1 from public.judges j where j.event_id = rounds.event_id and public.is_current_judge(j.id)));

drop policy if exists "assigned judge reads event criteria" on public.criteria;
create policy "assigned judge reads event criteria" on public.criteria
  for select using (exists (select 1 from public.judges j where j.event_id = criteria.event_id and public.is_current_judge(j.id)));

drop policy if exists "assigned judge reads allowed event teams" on public.teams;
create policy "assigned judge reads allowed event teams" on public.teams
  for select using (
    exists (
      select 1 from public.judges j
      where j.event_id = teams.event_id
        and public.is_current_judge(j.id)
        and public.can_judge_access_team(j.id, teams.id)
    )
  );

drop policy if exists "assigned judge reads event tracks" on public.tracks;
create policy "assigned judge reads event tracks" on public.tracks
  for select using (exists (select 1 from public.judges j where j.event_id = tracks.event_id and public.is_current_judge(j.id)));

drop policy if exists "assigned judge reads assigned panels" on public.panels;
create policy "assigned judge reads assigned panels" on public.panels
  for select using (exists (
    select 1 from public.panel_judges pj join public.judges j on j.id = pj.judge_id
    where pj.panel_id = panels.id and public.is_current_judge(j.id)
  ));

create policy "auth user can see unclaimed judge rows for their verified email" on public.judges
  for select using (
    user_id is null
    and public.current_user_email_verified()
    and lower(email) = lower(auth.jwt() ->> 'email')
  );

drop policy if exists "judge inserts own scores for assigned live work" on public.scores;
create policy "judge inserts own scores for assigned live work" on public.scores
  for insert with check (public.can_submit_score(judge_id, team_id, round_id, criterion_id, value));

drop policy if exists "organizer full access to own overrides" on public.overrides;
drop policy if exists "organizer reads own event overrides" on public.overrides;
drop policy if exists "organizer records valid event overrides" on public.overrides;
create policy "organizer reads own event overrides" on public.overrides
  for select using (public.is_organizer_of_event(event_id));
create policy "organizer records valid event overrides" on public.overrides
  for insert with check (
    public.is_organizer_of_event(event_id)
    and resolved_by = auth.uid()
    and round_id is not null
    and cardinality(team_ids) > 0
    and exists (select 1 from public.rounds r where r.id = overrides.round_id and r.event_id = overrides.event_id)
    and (select count(*) from public.teams t where t.id = any(overrides.team_ids) and t.event_id = overrides.event_id) = cardinality(overrides.team_ids)
  );

revoke all on public.public_leaderboard from public, anon, authenticated;
revoke all on public.current_scores from public, anon;
drop function if exists public.jwt_round_ids();
create or replace view public.current_scores with (security_invoker = on) as
  select distinct on (team_id, round_id, judge_id, criterion_id)
    team_id, round_id, judge_id, criterion_id, value, client_submitted_at, revision
  from public.scores
  order by team_id, round_id, judge_id, criterion_id, revision desc;
grant select on public.current_scores to authenticated;

