-- Re-check judge status in the database so a revoked judge's still-valid JWT
-- cannot continue reading event metadata, assignments, or prior scores.
create or replace function public.is_active_current_judge(check_judge_id uuid)
returns boolean
language sql
security definer
stable
set search_path = pg_catalog, public, auth, pg_temp
as $$
  select exists (
    select 1
    from public.judges j
    where j.id = check_judge_id
      and j.status = 'active'
      and (j.id = public.jwt_judge_id() or j.user_id = auth.uid())
  );
$$;
revoke all on function public.is_active_current_judge(uuid) from public, anon;
grant execute on function public.is_active_current_judge(uuid) to authenticated, service_role;

drop policy if exists "assigned judge reads event" on public.events;
create policy "assigned judge reads event" on public.events
  for select using (
    exists (
      select 1 from public.judges j
      where j.event_id = events.id and public.is_active_current_judge(j.id)
    )
  );

drop policy if exists "assigned judge reads event rounds" on public.rounds;
create policy "assigned judge reads event rounds" on public.rounds
  for select using (
    exists (
      select 1 from public.judges j
      where j.event_id = rounds.event_id and public.is_active_current_judge(j.id)
    )
  );

drop policy if exists "assigned judge reads event criteria" on public.criteria;
create policy "assigned judge reads event criteria" on public.criteria
  for select using (
    exists (
      select 1 from public.judges j
      where j.event_id = criteria.event_id and public.is_active_current_judge(j.id)
    )
  );

drop policy if exists "assigned judge reads allowed event teams" on public.teams;
create policy "assigned judge reads allowed event teams" on public.teams
  for select using (
    exists (
      select 1 from public.judges j
      where j.event_id = teams.event_id
        and public.is_active_current_judge(j.id)
        and public.can_judge_access_team(j.id, teams.id)
    )
  );

drop policy if exists "assigned judge reads event tracks" on public.tracks;
create policy "assigned judge reads event tracks" on public.tracks
  for select using (
    exists (
      select 1 from public.judges j
      where j.event_id = tracks.event_id and public.is_active_current_judge(j.id)
    )
  );

drop policy if exists "assigned judge reads assigned panels" on public.panels;
create policy "assigned judge reads assigned panels" on public.panels
  for select using (
    exists (
      select 1 from public.panel_judges pj
      join public.judges j on j.id = pj.judge_id
      where pj.panel_id = panels.id and public.is_active_current_judge(j.id)
    )
  );

drop policy if exists "judge reads own panel assignment" on public.panel_judges;
create policy "judge reads own panel assignment" on public.panel_judges
  for select using (public.is_active_current_judge(judge_id));

drop policy if exists "judge reads own row" on public.judges;
create policy "judge reads own row" on public.judges
  for select using (public.is_active_current_judge(id));

drop policy if exists "judge reads own scores" on public.scores;
create policy "judge reads own scores" on public.scores
  for select using (public.is_active_current_judge(judge_id));

-- This aggregate is used only by the organizer dashboard and includes scores
-- across judges. Keep it unavailable to judge sessions even if they know the
-- Data API endpoint.
create or replace view public.team_round_results with (security_invoker = on) as
with applicable_criteria as (
  select r.event_id, r.id as round_id, c.id as criterion_id, c.weight, c.max_score
  from public.rounds r
  join public.criteria c on c.event_id = r.event_id
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
  from public.current_scores cs
  join public.rounds r on r.id = cs.round_id
  join public.teams t on t.id = cs.team_id and t.event_id = r.event_id
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
  select o.event_id, o.round_id, selected.team_id, sum(o.amount) as adjustment
  from public.overrides o
  cross join lateral unnest(o.team_ids) as selected(team_id)
  group by o.event_id, o.round_id, selected.team_id
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
from public.teams t
join public.rounds r on r.event_id = t.event_id
left join team_averages ta on ta.event_id = t.event_id and ta.round_id = r.id and ta.team_id = t.id
left join criterion_counts cc on cc.event_id = r.event_id and cc.round_id = r.id
left join team_adjustments adj on adj.event_id = r.event_id and adj.round_id = r.id and adj.team_id = t.id
where public.is_organizer_of_event(t.event_id);

revoke all on public.team_round_results from public, anon, authenticated;
grant select on public.team_round_results to authenticated;
