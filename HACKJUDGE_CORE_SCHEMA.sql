-- ============================================================================
-- HACKJUDGE CORE — fresh Supabase project installer
-- Run this once in the SQL Editor of a NEW, EMPTY Supabase project.
-- Judge access uses verified Supabase Auth accounts matched by assigned email.
-- Magic-link/custom-JWT invite resolution is deliberately not included.
-- ============================================================================
begin;


-- ----------------------------------------------------------------------------
-- ENUMS
-- ----------------------------------------------------------------------------
create type event_status as enum ('draft', 'live', 'closed');
create type event_type as enum ('hackathon', 'pitch_comp', 'case_comp', 'other');
create type round_status as enum ('upcoming', 'live', 'closed');
create type tiebreak_rule as enum ('highest_criterion', 'most_recent_round', 'manual_only');
create type judge_status as enum ('invited', 'active');
create type team_source as enum ('csv', 'manual');

-- ----------------------------------------------------------------------------
-- ORGANIZERS
-- ----------------------------------------------------------------------------
create table organizers (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  phone text,
  created_at timestamptz not null default now()
);

-- REVIEW: auto-provision a profile row on signup, so events.organizer_id's FK
-- never fails on someone's first event just because the app forgot to insert
-- a profile row first. Harmless for judges who sign up too — this only ever
-- creates a name lookup row, it grants no event-creation rights on its own
-- (that's governed by events.organizer_id = auth.uid(), set at event-creation
-- time, not by the mere existence of an organizers row).
create or replace function handle_new_user_signup()
returns trigger language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
begin
  insert into public.organizers (id, name, phone)
  values (
    new.id, 
    coalesce(new.raw_user_meta_data ->> 'name', new.email, new.phone, 'User ' || substr(new.id::text, 1, 8)),
    new.phone
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user_signup();

-- ----------------------------------------------------------------------------
-- EVENTS
-- ----------------------------------------------------------------------------
create table events (
  id uuid primary key default gen_random_uuid(),
  organizer_id uuid not null references organizers(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 120),
  event_type event_type not null default 'hackathon',
  status event_status not null default 'draft',
  start_date date,
  end_date date,
  tiebreak_rule tiebreak_rule not null default 'manual_only',
  tiebreak_criterion_id uuid,
  sponsor_logo_url text,
  created_at timestamptz not null default now(),
  check (start_date is null or end_date is null or start_date <= end_date)
);

-- ----------------------------------------------------------------------------
-- ROUNDS
-- ----------------------------------------------------------------------------
create table rounds (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  order_index int not null default 0 check (order_index >= 0),
  status round_status not null default 'upcoming',
  advance_count int check (advance_count is null or advance_count >= 0),
  advanced_team_ids uuid[],
  created_at timestamptz not null default now(),
  unique (event_id, id),
  constraint rounds_event_order_index_unique unique (event_id, order_index)
    deferrable initially immediate
);

-- ----------------------------------------------------------------------------
-- CRITERIA
-- ----------------------------------------------------------------------------
create table criteria (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 40),
  weight numeric(5,2) not null default 0 check (weight between 0 and 100),
  max_score numeric(5,2) not null default 10 check (max_score > 0 and max_score <= 100),
  round_ids uuid[] not null default '{}',
  order_index int not null default 0 check (order_index >= 0),
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  unique (event_id, id)
);

alter table events
  add constraint events_tiebreak_criterion_same_event_fk
  foreign key (id, tiebreak_criterion_id) references criteria(event_id, id)
  on delete set null (tiebreak_criterion_id);

-- ----------------------------------------------------------------------------
-- TRACKS & PANELS
-- ----------------------------------------------------------------------------
create table tracks (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 40),
  created_at timestamptz not null default now(),
  unique (event_id, id)
);

create table panels (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  track_id uuid,
  created_at timestamptz not null default now(),
  foreign key (event_id, track_id) references tracks(event_id, id) on delete restrict
);

-- ----------------------------------------------------------------------------
-- TEAMS
-- ----------------------------------------------------------------------------
create table teams (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  members jsonb not null default '[]' check (jsonb_typeof(members) = 'array'),
  track_id uuid,
  source team_source not null default 'manual',
  created_at timestamptz not null default now(),
  foreign key (event_id, track_id) references tracks(event_id, id) on delete restrict
);

-- ----------------------------------------------------------------------------
-- JUDGES. Judges use normal verified Supabase Auth accounts. The organizer
-- assigns the email here; the judge signs up/signs in with that same email.
-- ----------------------------------------------------------------------------
create table judges (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  phone text,
  email text not null check (
    char_length(btrim(email)) between 3 and 120
    and email = lower(btrim(email))
    and email ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
  ),
  status judge_status not null default 'invited',
  round_ids uuid[] not null default '{}',
  user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Keep criterion and judge round assignments within their own event. Empty
-- arrays mean all rounds, matching the scoring and judge-access rules below.
create or replace function validate_event_round_assignments()
returns trigger language plpgsql set search_path = pg_catalog, public, auth, pg_temp as $$
begin
  if tg_op = 'UPDATE' then
    if new.event_id <> old.event_id then
      raise exception 'A criterion or judge cannot be moved to another event';
    end if;
  end if;
  if new.round_ids is null then
    raise exception 'Round assignments cannot be null';
  end if;
  if cardinality(new.round_ids) <> (
    select count(distinct selected.round_id)
    from unnest(new.round_ids) as selected(round_id)
  ) then
    raise exception 'Round assignments cannot contain duplicate or null IDs';
  end if;
  if exists (
    select 1
    from unnest(new.round_ids) as selected(round_id)
    left join public.rounds r on r.id = selected.round_id and r.event_id = new.event_id
    where r.id is null
  ) then
    raise exception 'Every assigned round must belong to the same event';
  end if;
  return new;
end;
$$;

create trigger criteria_round_assignments_before_write
  before insert or update on criteria
  for each row execute function validate_event_round_assignments();

-- Scoring configuration is historical data once judging starts. Changing a
-- criterion's weight, applicability, score range, or active state later would
-- silently recalculate already submitted scores.
create or replace function prevent_scoring_config_after_round_start()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, auth, pg_temp as $$
declare
  target_event_id uuid;
  previous_event_id uuid;
begin
  target_event_id := case when tg_op = 'DELETE' then old.event_id else new.event_id end;
  if tg_op = 'UPDATE' then previous_event_id := old.event_id; end if;

  -- Serialize criterion writes with start_event_round so a concurrent config
  -- update cannot slip through after the start function checks its rules.
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
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function prevent_scoring_config_after_round_start() from public, anon, authenticated;
create trigger criteria_lock_after_round_start
  before insert or update or delete on criteria
  for each row execute function prevent_scoring_config_after_round_start();

-- Keep the roster and assignment facts used by round eligibility stable after
-- judging begins. Judges may still claim an invitation (only user_id/status
-- changes); shortlist decisions remain independently revisable.
create or replace function guard_round_assignment_changes_after_start()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, auth, pg_temp as $$
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
revoke all on function guard_round_assignment_changes_after_start() from public, anon, authenticated;

create trigger teams_lock_after_round_start
  before insert or update or delete on teams
  for each row execute function guard_round_assignment_changes_after_start();
create trigger panels_lock_after_round_start
  before insert or update or delete on panels
  for each row execute function guard_round_assignment_changes_after_start();
create trigger judge_assignments_lock_after_round_start
  before update of event_id, round_ids, email on judges
  for each row execute function guard_round_assignment_changes_after_start();
create trigger judges_round_assignments_before_write
  before insert or update on judges
  for each row execute function validate_event_round_assignments();

-- Weighted scoring assumes active criterion weights total exactly 100.
-- This deferred check permits the event-creation RPC to insert its criteria
-- as a batch while rejecting any committed configuration with a bad total.
create or replace function validate_event_criteria_weight_total()
returns trigger language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
declare
  target_event_id uuid;
  active_weight_total numeric;
begin
  target_event_id := case when tg_op = 'DELETE' then old.event_id else new.event_id end;
  select coalesce(sum(weight), 0) into active_weight_total
  from public.criteria
  where event_id = target_event_id and archived_at is null;

  if active_weight_total <> 100 then
    raise exception 'Active criterion weights for an event must total exactly 100 (currently %)', active_weight_total;
  end if;
  return null;
end;
$$;

create constraint trigger criteria_weight_total_after_change
  after insert or update or delete on criteria
  deferrable initially deferred
  for each row execute function validate_event_criteria_weight_total();

-- ----------------------------------------------------------------------------
-- PANEL_JUDGES (mapping table)
-- ----------------------------------------------------------------------------
create table panel_judges (
  panel_id uuid not null references panels(id) on delete cascade,
  judge_id uuid not null references judges(id) on delete cascade,
  primary key (panel_id, judge_id)
);

create or replace function validate_panel_judge_same_event()
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

create trigger panel_judges_same_event_before_write
  before insert or update on panel_judges
  for each row execute function validate_panel_judge_same_event();

create trigger panel_judges_lock_after_round_start
  before insert or update or delete on panel_judges
  for each row execute function guard_round_assignment_changes_after_start();

-- ----------------------------------------------------------------------------
-- SCORES — append-only. A revision is a new row with a new client_id, never
-- an update to an existing one. See REVIEW note near the policies below for
-- why the UPDATE policy from the last draft was removed rather than kept.
-- ----------------------------------------------------------------------------
create table scores (
  id uuid primary key default gen_random_uuid(),
  revision bigint generated always as identity unique,
  client_id uuid not null unique,
  team_id uuid not null references teams(id) on delete cascade,
  round_id uuid not null references rounds(id) on delete cascade,
  judge_id uuid not null references judges(id) on delete cascade,
  criterion_id uuid not null references criteria(id) on delete cascade,
  value numeric(5,2) not null,
  client_submitted_at timestamptz not null default now(),
  synced_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- OVERRIDES
-- ----------------------------------------------------------------------------
create table overrides (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  round_id uuid not null,
  team_ids uuid[] not null,
  amount numeric(5,2) not null check (amount between -10 and 10),
  resolved_by uuid not null references organizers(id),
  resolution_note text check (resolution_note is null or char_length(resolution_note) <= 500),
  resolved_at timestamptz not null default now(),
  foreign key (event_id, round_id) references rounds(event_id, id) on delete cascade
);

-- ----------------------------------------------------------------------------
-- INDEXES
-- ----------------------------------------------------------------------------
create index idx_events_organizer on events(organizer_id);
create index idx_rounds_event on rounds(event_id);
create unique index idx_rounds_one_live_per_event on rounds(event_id) where status = 'live';
create index idx_criteria_event on criteria(event_id) where archived_at is null;
create index idx_teams_event on teams(event_id);
create index idx_judges_event on judges(event_id);
create index idx_judges_user on judges(user_id) where user_id is not null;
create unique index idx_judges_event_email_unique on judges(event_id, lower(email));
create unique index idx_judges_event_user_unique on judges(event_id, user_id) where user_id is not null;
create index idx_scores_team_round on scores(team_id, round_id);
create index idx_scores_judge on scores(judge_id);
create index idx_overrides_event on overrides(event_id);
create index idx_tracks_event on tracks(event_id);
create index idx_panels_event on panels(event_id);

-- Prevent accidental duplicate track names, including concurrent submissions.
-- The event-scoped advisory lock serializes competing writes before checking.
create or replace function prevent_duplicate_track_name()
returns trigger language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('track:' || new.event_id::text, 0));
  if exists (
    select 1 from public.tracks t
    where t.event_id = new.event_id
      and lower(btrim(t.name)) = lower(btrim(new.name))
      and t.id is distinct from new.id
  ) then
    raise exception 'A track with this name already exists for this event'
      using errcode = '23505', constraint = 'tracks_event_name_ci_key';
  end if;
  return new;
end;
$$;

drop trigger if exists tracks_unique_event_name on tracks;
create trigger tracks_unique_event_name
  before insert or update of event_id, name on tracks
  for each row execute function prevent_duplicate_track_name();

-- Keep judge email uniqueness even on projects where the original unique
-- index was not installed. Existing rows are left intact; new conflicts fail.
create or replace function prevent_duplicate_judge_email()
returns trigger language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('judge:' || new.event_id::text, 0));
  if exists (
    select 1 from public.judges j
    where j.event_id = new.event_id
      and lower(btrim(j.email)) = lower(btrim(new.email))
      and j.id is distinct from new.id
  ) then
    raise exception 'A judge with this email is already assigned to this event'
      using errcode = '23505', constraint = 'judges_event_email_ci_key';
  end if;
  return new;
end;
$$;

drop trigger if exists judges_unique_event_email on judges;
create trigger judges_unique_event_email
  before insert or update of event_id, email on judges
  for each row execute function prevent_duplicate_judge_email();
revoke all on function prevent_duplicate_track_name() from public, anon, authenticated;
revoke all on function prevent_duplicate_judge_email() from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- ----------------------------------------------------------------------------
create or replace function is_organizer_of_event(check_event_id uuid)
returns boolean language sql security definer stable set search_path = pg_catalog, public, auth, pg_temp as $$
  select exists (
    select 1 from public.events
    where id = check_event_id and organizer_id = auth.uid()
  );
$$;

-- Check the current database assignment on every request so disabling a judge
-- takes effect immediately for normal Supabase Auth sessions.
create or replace function is_active_current_judge(check_judge_id uuid)
returns boolean language sql security definer stable set search_path = pg_catalog, public, auth, pg_temp as $$
  select exists (
    select 1 from public.judges j
    where j.id = check_judge_id and j.status = 'active'
      and j.user_id = auth.uid()
  );
$$;
revoke all on function is_active_current_judge(uuid) from public, anon;
grant execute on function is_active_current_judge(uuid) to authenticated, service_role;

-- These helpers avoid a circular RLS evaluation between panels and
-- panel_judges. Keep the checks narrow and bind judge access to the active
-- authenticated judge row.
create or replace function is_organizer_of_panel(check_panel_id uuid)
returns boolean language sql security definer stable set search_path = pg_catalog, public, auth, pg_temp as $$
  select exists (
    select 1 from public.panels p
    where p.id = check_panel_id and public.is_organizer_of_event(p.event_id)
  );
$$;

create or replace function is_active_judge_assigned_to_panel(check_panel_id uuid)
returns boolean language sql security definer stable set search_path = pg_catalog, public, auth, pg_temp as $$
  select exists (
    select 1 from public.panel_judges pj
    where pj.panel_id = check_panel_id and public.is_active_current_judge(pj.judge_id)
  );
$$;

revoke all on function is_organizer_of_panel(uuid) from public, anon;
grant execute on function is_organizer_of_panel(uuid) to authenticated, service_role;
revoke all on function is_active_judge_assigned_to_panel(uuid) from public, anon;
grant execute on function is_active_judge_assigned_to_panel(uuid) to authenticated, service_role;

create or replace function can_judge_access_team(target_judge_id uuid, target_team_id uuid)
returns boolean language sql security definer stable set search_path = pg_catalog, public, auth, pg_temp as $$
  select exists (
    select 1
    from public.judges j
    join public.teams t on t.id = target_team_id and t.event_id = j.event_id
    join public.events e on e.id = j.event_id and e.status = 'live'
    join public.rounds current_round on current_round.event_id = j.event_id and current_round.status = 'live'
    where j.id = target_judge_id
      and j.status = 'active'
      and j.user_id = auth.uid()
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

revoke all on function can_judge_access_team(uuid, uuid) from public, anon;
grant execute on function can_judge_access_team(uuid, uuid) to authenticated;

-- REVIEW: new. auth.jwt()'s email claim is self-reported at signup and isn't
-- proof of ownership on its own — this checks the real column Supabase sets
-- once the address is actually confirmed.
create or replace function current_user_email_verified()
returns boolean language sql security definer stable set search_path = pg_catalog, public, auth, pg_temp as $$
  select coalesce((select email_confirmed_at is not null from auth.users where id = auth.uid()), false);
$$;

-- REVIEW: new. Replaces the raw judges UPDATE policy from the last draft.
-- A generic UPDATE policy that only checks "new user_id = auth.uid()" leaves
-- every other column open to being changed in the same call (name, email,
-- round_ids, even event_id). This function does exactly one thing and
-- nothing else is reachable through it.
create or replace function claim_judge_row(target_judge_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public, auth, pg_temp as $$
begin
  if auth.uid() is null or not current_user_email_verified() then
    raise exception 'A verified signed-in email is required to claim a judge invitation';
  end if;

  update public.judges
  set user_id = auth.uid(), status = 'active'
  where id = target_judge_id
    and user_id is null
    and lower(email) = lower(auth.jwt() ->> 'email');

  if not found then
    raise exception 'No matching unclaimed judge row for this email';
  end if;
end;
$$;

revoke all on function claim_judge_row(uuid) from public, anon;
grant execute on function claim_judge_row(uuid) to authenticated;

create or replace function can_submit_score(
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
      and j.user_id = auth.uid()
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

revoke all on function can_submit_score(uuid, uuid, uuid, uuid, numeric) from public, anon;
grant execute on function can_submit_score(uuid, uuid, uuid, uuid, numeric) to authenticated;

create or replace function start_event_round(target_event_id uuid, target_round_id uuid)
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
  if not exists (
    select 1 from public.criteria c
    where c.event_id = target_event_id and c.archived_at is null
      and (cardinality(c.round_ids) = 0 or target_round_id = any(c.round_ids))
  ) then
    raise exception 'The round requires at least one active scoring criterion';
  end if;
  if exists (
    select 1
    from public.teams t
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
        select 1
        from public.judges j
        where j.event_id = target_event_id
          and (
            (j.status = 'invited' and j.user_id is null
              and j.email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')
            or (j.status = 'active' and j.user_id is not null)
          )
          and (cardinality(j.round_ids) = 0 or target_round_id = any(j.round_ids))
          and (
            t.track_id is null
            or exists (
              select 1
              from public.panel_judges pj
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

create or replace function close_event_round(target_event_id uuid, target_round_id uuid)
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

create or replace function finalize_event_shortlist(
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

create or replace function reorder_event_rounds(target_event_id uuid, ordered_round_ids uuid[])
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

  -- Defer this unique key until the statement/transaction completes so a
  -- swap such as order 0 <-> 1 does not fail on a transient duplicate.
  set constraints rounds_event_order_index_unique deferred;
  update public.rounds r
  set order_index = ordered.position::integer - 1
  from unnest(ordered_round_ids) with ordinality as ordered(id, position)
  where r.id = ordered.id and r.event_id = target_event_id;
end;
$$;

revoke all on function start_event_round(uuid, uuid) from public, anon;
revoke all on function close_event_round(uuid, uuid) from public, anon;
revoke all on function finalize_event_shortlist(uuid, uuid, uuid[]) from public, anon;
revoke all on function reorder_event_rounds(uuid, uuid[]) from public, anon;
grant execute on function start_event_round(uuid, uuid) to authenticated;
grant execute on function close_event_round(uuid, uuid) to authenticated;
grant execute on function finalize_event_shortlist(uuid, uuid, uuid[]) to authenticated;
grant execute on function reorder_event_rounds(uuid, uuid[]) to authenticated;

create or replace function guard_event_status_transition()
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

create trigger guard_event_status_transition_before_update
  before update of status on events
  for each row execute function guard_event_status_transition();

create or replace function enforce_event_collection_limit()
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

create trigger limit_event_teams before insert on teams for each row execute function enforce_event_collection_limit();
create trigger limit_event_judges before insert on judges for each row execute function enforce_event_collection_limit();
create trigger limit_event_tracks before insert on tracks for each row execute function enforce_event_collection_limit();
create trigger limit_event_panels before insert on panels for each row execute function enforce_event_collection_limit();
create trigger limit_event_rounds before insert on rounds for each row execute function enforce_event_collection_limit();
create trigger limit_event_criteria before insert on criteria for each row execute function enforce_event_collection_limit();

create or replace function create_event_setup(
  new_event_id uuid,
  event_name text,
  event_kind event_type,
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
         coalesce((item ->> 'order_index')::integer, position - 1)
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

revoke all on function create_event_setup(uuid, text, event_type, jsonb, jsonb) from public, anon;
grant execute on function create_event_setup(uuid, text, event_type, jsonb, jsonb) to authenticated;

create or replace function stamp_score_revision()
returns trigger language plpgsql set search_path = public as $$
begin
  new.client_submitted_at := clock_timestamp();
  new.synced_at := clock_timestamp();
  return new;
end;
$$;

create trigger stamp_score_revision_before_insert
  before insert on scores
  for each row execute function stamp_score_revision();

-- ----------------------------------------------------------------------------
-- ROW LEVEL SECURITY
-- ----------------------------------------------------------------------------
alter table organizers enable row level security;
alter table events enable row level security;
alter table rounds enable row level security;
alter table criteria enable row level security;
alter table tracks enable row level security;
alter table panels enable row level security;
alter table panel_judges enable row level security;
alter table teams enable row level security;
alter table judges enable row level security;
alter table scores enable row level security;
alter table overrides enable row level security;

-- ORGANIZERS
create policy "organizer reads own profile" on organizers
  for select using (id = auth.uid());
create policy "organizer updates own profile" on organizers
  for update using (id = auth.uid());
create policy "organizer profile created on signup" on organizers
  for insert with check (id = auth.uid());

-- EVENTS
create policy "organizer reads own events" on events
  for select using (organizer_id = auth.uid());
create policy "organizer creates draft events" on events
  for insert with check (organizer_id = auth.uid() and status = 'draft');
create policy "organizer updates own event settings" on events
  for update using (organizer_id = auth.uid()) with check (organizer_id = auth.uid());
create policy "assigned judge reads event" on events
  for select using (exists (select 1 from judges j where j.event_id = events.id and is_active_current_judge(j.id)));
create policy "verified judge reads event to claim assignment" on events
  for select using (exists (
    select 1 from judges j
    where j.event_id = events.id
      and j.user_id is null
      and lower(j.email) = lower(auth.jwt() ->> 'email')
      and current_user_email_verified()
  ));

-- ROUNDS, CRITERIA, TEAMS
create policy "organizer reads own rounds" on rounds
  for select using (is_organizer_of_event(event_id));
create policy "organizer inserts upcoming rounds" on rounds
  for insert with check (is_organizer_of_event(event_id) and status = 'upcoming');
create policy "assigned judge reads event rounds" on rounds
  for select using (exists (select 1 from judges j where j.event_id = rounds.event_id and is_active_current_judge(j.id)));

create policy "organizer reads own criteria" on criteria
  for select using (is_organizer_of_event(event_id));
create policy "organizer inserts own criteria" on criteria
  for insert with check (is_organizer_of_event(event_id));
create policy "organizer updates own criteria" on criteria
  for update using (is_organizer_of_event(event_id)) with check (is_organizer_of_event(event_id));
create policy "assigned judge reads event criteria" on criteria
  for select using (exists (select 1 from judges j where j.event_id = criteria.event_id and is_active_current_judge(j.id)));

create policy "organizer reads own teams" on teams
  for select using (is_organizer_of_event(event_id));
create policy "organizer inserts own teams" on teams
  for insert with check (is_organizer_of_event(event_id));
create policy "organizer updates own teams" on teams
  for update using (is_organizer_of_event(event_id)) with check (is_organizer_of_event(event_id));
create policy "assigned judge reads allowed event teams" on teams
  for select using (
    exists (
      select 1 from judges j
      where j.event_id = teams.event_id
        and is_active_current_judge(j.id)
        and can_judge_access_team(j.id, teams.id)
    )
  );

-- TRACKS, PANELS
create policy "organizer reads own tracks" on tracks
  for select using (is_organizer_of_event(event_id));
create policy "organizer inserts own tracks" on tracks
  for insert with check (is_organizer_of_event(event_id));
create policy "organizer updates own tracks" on tracks
  for update using (is_organizer_of_event(event_id)) with check (is_organizer_of_event(event_id));
create policy "assigned judge reads event tracks" on tracks
  for select using (exists (select 1 from judges j where j.event_id = tracks.event_id and is_active_current_judge(j.id)));

create policy "organizer reads own panels" on panels
  for select using (is_organizer_of_event(event_id));
create policy "organizer inserts own panels" on panels
  for insert with check (is_organizer_of_event(event_id));
create policy "organizer updates own panels" on panels
  for update using (is_organizer_of_event(event_id)) with check (is_organizer_of_event(event_id));
create policy "assigned judge reads assigned panels" on panels
  for select using (is_active_judge_assigned_to_panel(id));

-- REVIEW: dropped the public read policy on panel_judges — there's no
-- legitimate anon/display-mode use case for reading judge-to-panel pairing,
-- only organizer (for assignment) and the judge session itself need it.
create policy "organizer full access to own panel_judges" on panel_judges
  for all using (is_organizer_of_panel(panel_id))
  with check (is_organizer_of_panel(panel_id));
create policy "judge reads own panel assignment" on panel_judges
  for select using (is_active_current_judge(judge_id));

-- JUDGES
create policy "organizer reads own judges" on judges
  for select using (is_organizer_of_event(event_id));
create policy "organizer inserts own judges" on judges
  for insert with check (is_organizer_of_event(event_id));
create policy "organizer updates own judges" on judges
  for update using (is_organizer_of_event(event_id)) with check (is_organizer_of_event(event_id));
create policy "judge reads own row" on judges
  for select using (is_active_current_judge(id));

-- REVIEW: now requires a verified email, not just a matching JWT claim.
-- The actual claim WRITE happens only through claim_judge_row() above —
-- no raw UPDATE policy is exposed for this anymore.
create policy "auth user can see unclaimed judge rows for their email" on judges
  for select using (
    user_id is null
    and current_user_email_verified()
    and lower(email) = lower(auth.jwt() ->> 'email')
  );

-- SCORES
-- REVIEW: added c.archived_at is null (an archived criterion shouldn't
-- accept new scores) and the track/panel check (a no-op — always true —
-- for any event that isn't using tracks, since t.track_id is null there).
create policy "judge inserts own scores for assigned live work" on scores
  for insert with check (can_submit_score(judge_id, team_id, round_id, criterion_id, value));

-- REVIEW: removed the scores UPDATE policy. It contradicted the append-only
-- design (a revision should be a new row, new client_id — that's what keeps
-- the audit trail intact for tie-break disputes) and its with check didn't
-- actually restrict team_id/round_id/criterion_id from being changed on an
-- existing row. Offline-retry idempotency doesn't need UPDATE at all: the
-- app does INSERT ... ON CONFLICT (client_id) DO NOTHING, which only needs
-- INSERT privilege.

create policy "judge reads own scores" on scores
  for select using (is_active_current_judge(judge_id));
create policy "organizer reads all scores for own event" on scores
  for select using (
    exists (
      select 1 from rounds r where r.id = round_id and is_organizer_of_event(r.event_id)
    )
  );

-- OVERRIDES are append-only decision records.
create policy "organizer reads own event overrides" on overrides
  for select using (is_organizer_of_event(event_id));
create policy "organizer records valid event overrides" on overrides
  for insert with check (
    is_organizer_of_event(event_id)
    and resolved_by = auth.uid()
    and cardinality(team_ids) > 0
    and exists (select 1 from rounds r where r.id = overrides.round_id and r.event_id = overrides.event_id)
    and (select count(*) from teams t where t.id = any(overrides.team_ids) and t.event_id = overrides.event_id) = cardinality(overrides.team_ids)
  );

-- ----------------------------------------------------------------------------
-- CURRENT_SCORES — for direct organizer/judge introspection. security_invoker
-- is correct here: whoever queries it should only see what their own RLS
-- allows. Do NOT build public_leaderboard on top of this view — see below.
-- ----------------------------------------------------------------------------
create view current_scores with (security_invoker = on) as
  select distinct on (team_id, round_id, judge_id, criterion_id)
    team_id, round_id, judge_id, criterion_id, value, client_submitted_at, revision
  from scores
  order by team_id, round_id, judge_id, criterion_id, revision desc;

-- ----------------------------------------------------------------------------
-- PUBLIC_LEADERBOARD
-- No public leaderboard view is created. It must be implemented as a
-- privacy-safe, canonical weighted projection before public release.
-- ----------------------------------------------------------------------------
grant select on current_scores to authenticated;

-- One canonical organizer-visible scoring projection. A judge contributes to
-- a team's round result only after scoring every active criterion assigned to
-- that round. Missing criteria are incomplete, while an explicit zero is a
-- valid score. Team results with no complete judge remain NULL (unscored).
create view team_round_results with (security_invoker = on) as
with applicable_criteria as (
  select r.event_id, r.id as round_id, c.id as criterion_id, c.weight, c.max_score
  from rounds r
  join criteria c on c.event_id = r.event_id
    and c.archived_at is null
    and c.max_score > 0
    and c.weight between 0 and 100
    and (cardinality(c.round_ids) = 0 or r.id = any(c.round_ids))
), criterion_counts as (
  select event_id, round_id, count(*)::integer as applicable_criterion_count
  from applicable_criteria
  group by event_id, round_id
), judge_totals as (
  select r.event_id, cs.round_id, cs.team_id, cs.judge_id,
    sum((cs.value / ac.max_score) * ac.weight) as total,
    count(distinct cs.criterion_id)::integer as scored_criterion_count
  from current_scores cs
  join rounds r on r.id = cs.round_id
  join teams t on t.id = cs.team_id and t.event_id = r.event_id
  join applicable_criteria ac on ac.event_id = r.event_id
    and ac.round_id = cs.round_id and ac.criterion_id = cs.criterion_id
  group by r.event_id, cs.round_id, cs.team_id, cs.judge_id
), complete_judge_totals as (
  select jt.event_id, jt.round_id, jt.team_id, jt.judge_id, jt.total
  from judge_totals jt
  join criterion_counts cc on cc.event_id = jt.event_id and cc.round_id = jt.round_id
    and jt.scored_criterion_count = cc.applicable_criterion_count
), team_averages as (
  select event_id, round_id, team_id, round(avg(total), 2) as average_score,
    count(*)::integer as completed_judge_count
  from complete_judge_totals
  group by event_id, round_id, team_id
), team_adjustments as (
  select o.event_id, o.round_id, team_id, sum(o.amount) as adjustment
  from overrides o
  cross join lateral unnest(o.team_ids) as selected(team_id)
  group by o.event_id, o.round_id, team_id
)
select t.event_id, r.id as round_id, t.id as team_id,
  case
    when coalesce(ta.completed_judge_count, 0) > 0 or adj.adjustment is not null
      then round(coalesce(ta.average_score, 0) + coalesce(adj.adjustment, 0), 2)
    else null
  end as score,
  coalesce(ta.completed_judge_count, 0)::integer as completed_judge_count,
  coalesce(cc.applicable_criterion_count, 0)::integer as applicable_criterion_count,
  coalesce(adj.adjustment, 0) as adjustment,
  (coalesce(ta.completed_judge_count, 0) > 0 or adj.adjustment is not null) as has_result
from teams t
join rounds r on r.event_id = t.event_id
left join team_averages ta on ta.event_id = t.event_id and ta.round_id = r.id and ta.team_id = t.id
left join criterion_counts cc on cc.event_id = t.event_id and cc.round_id = r.id
left join team_adjustments adj on adj.event_id = t.event_id and adj.round_id = r.id and adj.team_id = t.id
where is_organizer_of_event(t.event_id);

grant select on team_round_results to authenticated;

-- Application roles cannot physically delete event records. Keep score and
-- participant history until a recoverable archive/retention workflow exists.
revoke delete on table events, rounds, criteria, teams, tracks, panels, judges
  from public, anon, authenticated;

-- New Supabase projects may not grant Data API privileges on newly created
-- objects. Keep grants explicit and least-privilege; RLS policies above still
-- decide which rows each signed-in account can access.
grant usage on schema public to anon, authenticated, service_role;
revoke all on type event_status, event_type, round_status, tiebreak_rule,
  judge_status, team_source from public, anon, authenticated, service_role;
grant usage on type event_status, event_type, round_status, tiebreak_rule,
  judge_status, team_source to authenticated, service_role;

revoke all on table organizers, events, rounds, criteria, tracks, panels,
  panel_judges, teams, judges, scores, overrides
  from public, anon, authenticated, service_role;

grant select, update on table organizers to authenticated;
grant select, insert, update on table events to authenticated;
grant select, insert on table rounds to authenticated;
grant select, insert, update on table criteria to authenticated;
grant select, insert, update on table tracks to authenticated;
grant select, insert, update on table panels to authenticated;
grant select, insert, update, delete on table panel_judges to authenticated;
grant select, insert, update on table teams to authenticated;
grant select, insert, update on table judges to authenticated;
grant select, insert on table scores to authenticated;
grant select, insert on table overrides to authenticated;
grant all on table organizers, events, rounds, criteria, tracks, panels,
  panel_judges, teams, judges, scores, overrides to service_role;

revoke all on function is_organizer_of_event(uuid) from public, anon;
grant execute on function is_organizer_of_event(uuid) to authenticated;
grant execute on function is_organizer_of_panel(uuid) to authenticated;
grant execute on function is_active_judge_assigned_to_panel(uuid) to authenticated;
revoke all on function current_user_email_verified() from public, anon;
grant execute on function current_user_email_verified() to authenticated;

revoke all on table current_scores from public, anon, authenticated;
grant select on current_scores to authenticated;
revoke all on table team_round_results from public, anon, authenticated;
grant select on team_round_results to authenticated;

commit;
