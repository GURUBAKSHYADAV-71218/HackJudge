-- Canonical weighted results. Incomplete judge submissions do not contribute;
-- a submitted zero is valid. Results without a complete judge score remain NULL.
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
left join criterion_counts cc on cc.event_id = t.event_id and cc.round_id = r.id
left join team_adjustments adj on adj.event_id = t.event_id and adj.round_id = r.id and adj.team_id = t.id;

revoke all on public.team_round_results from public, anon, authenticated;
grant select on public.team_round_results to authenticated;
