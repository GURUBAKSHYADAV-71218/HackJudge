-- READ-ONLY diagnostics for the existing HackJudge database.
-- Run with: supabase db query --linked --file supabase/preflight_existing_data.sql
-- This reports counts only; it does not modify schema or application data.
with checks (check_name, issue_count) as (
  select 'duplicate_round_order_groups', count(*)::bigint
  from (
    select event_id, order_index
    from public.rounds
    group by event_id, order_index
    having count(*) > 1
  ) duplicates
  union all
  select 'events_with_multiple_live_rounds', count(*)::bigint
  from (
    select event_id
    from public.rounds
    where status = 'live'
    group by event_id
    having count(*) > 1
  ) conflicts
  union all
  select 'cross_event_panel_judge_assignments', count(*)::bigint
  from public.panel_judges pj
  join public.panels p on p.id = pj.panel_id
  join public.judges j on j.id = pj.judge_id
  where p.event_id <> j.event_id
  union all
  select 'cross_event_panel_track_references', count(*)::bigint
  from public.panels p
  join public.tracks t on t.id = p.track_id
  where p.event_id <> t.event_id
  union all
  select 'cross_event_team_track_references', count(*)::bigint
  from public.teams t
  join public.tracks tr on tr.id = t.track_id
  where t.event_id <> tr.event_id
  union all
  select 'cross_event_tiebreak_criteria', count(*)::bigint
  from public.events e
  join public.criteria c on c.id = e.tiebreak_criterion_id
  where e.id <> c.event_id
  union all
  select 'cross_event_score_references', count(*)::bigint
  from public.scores s
  join public.teams t on t.id = s.team_id
  join public.rounds r on r.id = s.round_id
  join public.judges j on j.id = s.judge_id
  join public.criteria c on c.id = s.criterion_id
  where t.event_id <> r.event_id
     or t.event_id <> j.event_id
     or t.event_id <> c.event_id
  union all
  select 'score_values_outside_criterion_range', count(*)::bigint
  from public.scores s
  join public.criteria c on c.id = s.criterion_id
  where s.value < 0 or s.value > c.max_score
  union all
  select 'event_rows_violating_new_checks', count(*)::bigint
  from public.events
  where char_length(btrim(name)) not between 1 and 120
     or (start_date is not null and end_date is not null and start_date > end_date)
  union all
  select 'round_rows_violating_new_checks', count(*)::bigint
  from public.rounds
  where char_length(btrim(name)) not between 1 and 80
     or order_index < 0
     or (advance_count is not null and advance_count < 0)
  union all
  select 'criteria_rows_violating_new_checks', count(*)::bigint
  from public.criteria
  where char_length(btrim(name)) not between 1 and 40
     or weight not between 0 and 100
     or max_score <= 0 or max_score > 100
     or order_index < 0
  union all
  select 'track_rows_violating_new_checks', count(*)::bigint
  from public.tracks
  where char_length(btrim(name)) not between 1 and 40
  union all
  select 'panel_rows_violating_new_checks', count(*)::bigint
  from public.panels
  where char_length(btrim(name)) not between 1 and 60
  union all
  select 'team_rows_violating_new_checks', count(*)::bigint
  from public.teams
  where char_length(btrim(name)) not between 1 and 60
     or jsonb_typeof(members) <> 'array'
  union all
  select 'judge_rows_violating_new_checks', count(*)::bigint
  from public.judges
  where char_length(btrim(name)) not between 1 and 80
     or (email is not null and char_length(email) > 120)
  union all
  select 'overrides_with_cross_event_team_ids', count(*)::bigint
  from public.overrides o
  cross join lateral unnest(o.team_ids) as selected(team_id)
  join public.teams t on t.id = selected.team_id
  where t.event_id <> o.event_id
)
select check_name, issue_count
from checks
order by check_name;
