export const GRADE_MAP = { 'A+':10, A:9, 'B+':8, B:7, 'C+':6, C:5, D:3, F:0 };

export const isScorableCriterion = criterion => !criterion.archived_at
  && Number(criterion.max_score) > 0
  && Number(criterion.weight) >= 0
  && Number(criterion.weight) <= 100;

export function calculateWeightedTotal(criteria, values) {
  return criteria.reduce((sum, criterion) => {
    const rawValue = values?.[criterion.id];
    if (rawValue === undefined || rawValue === null || rawValue === '') return sum;
    const value = Number(rawValue);
    const maxScore = Number(criterion.max_score);
    const weight = Number(criterion.weight);
    if (!isScorableCriterion(criterion) || !Number.isFinite(value) || !Number.isFinite(maxScore) || !Number.isFinite(weight)) return sum;
    return sum + (value / maxScore) * weight;
  }, 0);
}

// Database-generated revision values define which append-only score is current.
function getActiveScores(scores) {
  const latest = new Map(); // key -> score row
  for (const s of scores) {
    const key = `${s.round_id}_${s.judge_id}_${s.team_id}_${s.criterion_id}`;
    if (!latest.has(key) || Number(s.revision) > Number(latest.get(key).revision)) {
      latest.set(key, s);
    }
  }
  return Array.from(latest.values());
}

export function getAvg(ev, roundId, teamId) {
  const result = ev.team_round_results?.find(row => row.round_id === roundId && row.team_id === teamId);
  return result?.has_result ? Number(result.score) : null;
}

export function getOverallAvg(ev, teamId) {
  const results = sortedRounds(ev)
    .map(round => getAvg(ev, round.id, teamId))
    .filter(score => score !== null && Number.isFinite(score));
  if (!results.length) return null;
  return Number((results.reduce((sum, score) => sum + score, 0) / results.length).toFixed(2));
}

export function compareScoreRows(scoreA, teamA, scoreB, teamB) {
  if (scoreA === null && scoreB !== null) return 1;
  if (scoreB === null && scoreA !== null) return -1;
  if (scoreA !== null && scoreB !== null && scoreA !== scoreB) return scoreB - scoreA;
  return teamA.name.localeCompare(teamB.name) || teamA.id.localeCompare(teamB.id);
}

export function competitionRank(teams, index, scoreForTeam) {
  const score = scoreForTeam(teams[index]);
  if (score === null || score === undefined) return null;
  return 1 + teams.slice(0, index).filter(team => {
    const previousScore = scoreForTeam(team);
    return previousScore !== null && previousScore !== undefined && previousScore > score;
  }).length;
}

export function getJudgeTotal(ev, roundId, judgeId, teamId) {
  if (!ev.scores) return 0;
  const activeScores = getActiveScores(ev.scores).filter(
    s => s.round_id === roundId && s.judge_id === judgeId && s.team_id === teamId
  );

  const values = {};
  for (const s of activeScores) {
    const p = ev.criteria?.find(c => c.id === s.criterion_id);
    if (!p || !isScorableCriterion(p) || p.type === 'text') continue;
    const isActiveForRound = p.round_ids?.length === 0 || p.round_ids?.includes(roundId);
    if (!isActiveForRound) continue;
    values[p.id] = s.value;
  }
  return +calculateWeightedTotal(ev.criteria?.filter(p => isScorableCriterion(p) && (p.round_ids?.length === 0 || p.round_ids?.includes(roundId))) || [], values).toFixed(1);
}

export function isJudgeComplete(ev, roundId, judgeId, teamId) {
  const criteria = (ev.criteria || []).filter(p => isScorableCriterion(p) && (p.round_ids?.length === 0 || p.round_ids?.includes(roundId)));
  if (!criteria.length) return false;
  const scoredIds = new Set(getActiveScores(ev.scores || [])
    .filter(s => s.round_id === roundId && s.judge_id === judgeId && s.team_id === teamId)
    .map(s => s.criterion_id));
  return criteria.every(criterion => scoredIds.has(criterion.id));
}

export function getAssignedJudges(ev, roundId, team) {
  return (ev.judges || []).filter(judge => {
    if (judge.round_ids?.length && !judge.round_ids.includes(roundId)) return false;
    if (!team.track_id) return true;
    return (ev.panel_judges || []).some(assignment => {
      if (assignment.judge_id !== judge.id) return false;
      const panel = (ev.panels || []).find(item => item.id === assignment.panel_id);
      return panel?.track_id === team.track_id;
    });
  });
}

export function getEligibleJudges(ev, roundId, team) {
  return getAssignedJudges(ev, roundId, team).filter(judge =>
    (judge.status === 'invited' && !judge.user_id && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(judge.email || '')) ||
    (judge.status === 'active' && Boolean(judge.user_id))
  );
}

export function getRoundJudgeProgress(ev, roundId) {
  const roundTeams = getTeamsForRound(ev, roundId);
  const judgeTeams = new Map();
  roundTeams.forEach(team => {
    getAssignedJudges(ev, roundId, team).forEach(judge => {
      if (!judgeTeams.has(judge.id)) judgeTeams.set(judge.id, []);
      judgeTeams.get(judge.id).push(team);
    });
  });

  const assignments = [...judgeTeams.entries()];
  return {
    total: assignments.length,
    completed: assignments.filter(([judgeId, assignedTeams]) =>
      assignedTeams.every(team => isJudgeComplete(ev, roundId, judgeId, team.id))
    ).length,
  };
}

export function getTeamsForRound(ev, roundId) {
  const rounds = sortedRounds(ev);
  const roundIndex = rounds.findIndex(round => round.id === roundId);
  const teams = ev.teams || [];
  if (roundIndex <= 0) return teams;
  const advancedIds = rounds[roundIndex - 1].advanced_team_ids;
  if (!Array.isArray(advancedIds)) return [];
  const advancedSet = new Set(advancedIds);
  return teams.filter(team => advancedSet.has(team.id));
}

export function sortedRounds(ev) {
  if (!ev?.rounds) return [];
  return [...ev.rounds].sort((a, b) => a.order_index - b.order_index || new Date(a.created_at) - new Date(b.created_at)).map((r, i) => ({
    ...r,
    number: i + 1 // Add logical number based on creation order
  }));
}
