import test from 'node:test';
import assert from 'node:assert/strict';
import { fetchAllRows } from '../src/lib/fetchAllRows.js';
import {
  calculateWeightedTotal,
  getOverallAvg,
  isJudgeComplete,
} from '../src/utils/scoring.js';

test('weighted total normalizes each criterion to its own maximum', () => {
  const criteria = [
    { id: 'design', max_score: 10, weight: 60 },
    { id: 'impact', max_score: 20, weight: 40 },
  ];

  assert.equal(calculateWeightedTotal(criteria, { design: 5, impact: 10 }), 50);
});

test('a missing criterion is incomplete while an explicit zero is a score', () => {
  const ev = {
    criteria: [
      { id: 'a', max_score: 10, weight: 50, round_ids: [] },
      { id: 'b', max_score: 10, weight: 50, round_ids: [] },
    ],
    scores: [
      { round_id: 'r1', judge_id: 'j1', team_id: 't1', criterion_id: 'a', value: 0, revision: 1 },
    ],
  };

  assert.equal(isJudgeComplete(ev, 'r1', 'j1', 't1'), false);
  ev.scores.push({ round_id: 'r1', judge_id: 'j1', team_id: 't1', criterion_id: 'b', value: 0, revision: 2 });
  assert.equal(isJudgeComplete(ev, 'r1', 'j1', 't1'), true);
});

test('overall average includes scored zeroes and omits rounds without a result', () => {
  const ev = {
    rounds: [
      { id: 'r1', order_index: 0 },
      { id: 'r2', order_index: 1 },
      { id: 'r3', order_index: 2 },
    ],
    team_round_results: [
      { round_id: 'r1', team_id: 't1', score: 0, has_result: true },
      { round_id: 'r2', team_id: 't1', score: 80, has_result: true },
      { round_id: 'r3', team_id: 't1', score: null, has_result: false },
    ],
  };

  assert.equal(getOverallAvg(ev, 't1'), 40);
});

test('fetchAllRows requests every page, including an exact full final page', async () => {
  const requestedRanges = [];
  const pages = [
    Array.from({ length: 2 }, (_, id) => ({ id })),
    [{ id: 2 }],
  ];
  const rows = await fetchAllRows(async (from, to) => {
    requestedRanges.push([from, to]);
    return { data: pages[from / 2] || [], error: null };
  }, 2);

  assert.deepEqual(rows.map(row => row.id), [0, 1, 2]);
  assert.deepEqual(requestedRanges, [[0, 1], [2, 3]]);
});

test('fetchAllRows propagates Supabase errors and rejects invalid pages', async () => {
  const dbError = new Error('database unavailable');
  await assert.rejects(() => fetchAllRows(async () => ({ data: null, error: dbError })), dbError);
  await assert.rejects(() => fetchAllRows(async () => ({ data: null, error: null })), /row array/);
  await assert.rejects(() => fetchAllRows(async () => ({ data: [], error: null }), 0), /pageSize/);
});
