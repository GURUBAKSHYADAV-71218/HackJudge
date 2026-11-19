import { useState, useEffect } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { Play, Lock, BarChart2, CheckSquare, Plus, Check, Printer, ArrowUp, ArrowDown } from 'lucide-react';
import { Btn, Card, SectionHead, Empty, Alert, ChipRow, Motion, SplitFlapDigit, Input, Textarea, ConfirmModal, Tooltip } from '../../components/ui';
import { toast } from '../../lib/toast';
import { ReportTemplate } from '../../components/ReportTemplate.jsx';
import { useEventData } from '../../hooks/useEventData.jsx';
import { compareScoreRows, competitionRank, getAssignedJudges, getAvg, getEligibleJudges, getJudgeTotal, getOverallAvg, getRoundJudgeProgress, getTeamsForRound, isJudgeComplete, isScorableCriterion, sortedRounds } from '../../utils/scoring.js';
import { supabase } from '../../lib/supabase';

export function RoundsTab() {
  const { data: ev, isLoading } = useEventData();
  const queryClient = useQueryClient();
  const rounds = sortedRounds(ev);
  const canReorder = ev?.status === 'draft' && rounds.every(round => round.status === 'upcoming');
  const latest = rounds[rounds.length-1] || null;
  const hasActive = latest?.status === 'live';
  const nextRound = rounds.find(round => round.status === 'upcoming') || null;
  const roundCriteria = (ev?.criteria || []).filter(criterion => isScorableCriterion(criterion) &&
    (criterion.round_ids?.length === 0 || criterion.round_ids?.includes(nextRound?.id)));
  const roundTeams = nextRound ? getTeamsForRound(ev, nextRound.id) : [];
  const uncoveredTeam = nextRound && roundCriteria.length > 0
    ? roundTeams.find(team => getEligibleJudges(ev, nextRound.id, team).length === 0)
    : null;
  const hasSetupBasics = roundCriteria.length > 0 && roundTeams.length > 0;
  const canStart = hasSetupBasics && !uncoveredTeam;
  const [confirmLockId, setConfirmLockId] = useState(null);

  async function reorderRound(index, offset) {
    const next = [...rounds];
    const target = index + offset;
    if (target < 0 || target >= next.length) return;
    [next[index], next[target]] = [next[target], next[index]];
    const { error } = await supabase.rpc('reorder_event_rounds', {
      target_event_id: ev.id,
      ordered_round_ids: next.map(round => round.id),
    });
    if (error) return toast(error.message || 'Could not reorder rounds');
    await queryClient.invalidateQueries({ queryKey: ['eventData'] });
  }

  if (isLoading) return null;

  return (
    <div style={{ display:'flex', flexDirection:'column', gap:22, paddingTop:24 }}>
      <Motion type="fadeUp">
        <Card>
          <SectionHead title="Round Control" sub="Start evaluation rounds, then lock them once all judges have finished scoring" />

          {!hasSetupBasics && (
            <Alert variant="warn">
              To start a round you need at least one <strong>parameter</strong>, one <strong>judge</strong>, and one <strong>team</strong> — configure these in the Setup tab.
            </Alert>
          )}
          {hasSetupBasics && uncoveredTeam && (
            <Alert variant="warn">
              Assign at least one judge to {uncoveredTeam.name}{uncoveredTeam.track_id ? ' and its track' : ''} for this round before starting it.
            </Alert>
          )}

          <div style={{ display:'flex', gap:12, flexWrap:'wrap', alignItems:'center' }}>
            <Btn variant="success" disabled={!canStart || hasActive || !nextRound} onClick={async () => {
              // Find the first upcoming round
              if (!nextRound) { toast('No upcoming rounds to start.'); return; }
              try {
                const { error } = await supabase.rpc('start_event_round', {
                  target_event_id: ev.id,
                  target_round_id: nextRound.id,
                });
                if (error) throw error;
                await queryClient.invalidateQueries({ queryKey: ['eventData'] });
                toast(`Round ${nextRound.number} started — judges can now score`);
              } catch (e) { toast(e.message || 'Failed to start round'); }
            }}>
              <Play size={14} /> Start Round {nextRound?.number || ''}
            </Btn>
            {hasActive && (
              <Btn variant="danger" onClick={()=>setConfirmLockId(latest.id)}>
                <Lock size={14} /> Lock Round {latest.number}
              </Btn>
            )}
          </div>

          {hasActive && (
            <p style={{ marginTop:14, fontSize:13, color:'var(--teal)', fontWeight:500 }}>
              Round {latest.number} is live — judges can score teams now.
            </p>
          )}
        </Card>
      </Motion>

      {rounds.length > 0 && (
        <Motion delay={1} type="fadeUp">
          <Card>
            <SectionHead title="Round History" />
            {rounds.map((r, i) => {
              const judgeProgress = getRoundJudgeProgress(ev, r.id);
              const isActive = r.status === 'live';
              const isLocked = r.status === 'closed';
              // Advance count or shortlists are not explicitly in the schema yet beyond `advance_count`.
              // We'll show advance_count if it exists.
              
              return (
                <div key={r.id} style={{
                  background: isActive ? 'var(--green-s)' : 'var(--panel-2)',
                  border:`1px solid ${isActive?'var(--green)':'var(--line)'}`,
                  borderRadius:12, padding:'20px 24px', marginBottom:12, transition:'all .2s',
                }}>
                  <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', marginBottom:12 }}>
                    <span style={{ fontFamily:'var(--font-display)', fontSize:20, fontWeight:600, color:'var(--ink)' }}>Round {r.number}: {r.name}</span>
                    <div style={{ display:'flex', alignItems:'center', gap:8 }}>
                    {canReorder && <div style={{ display:'flex' }}>
                      <button type="button" aria-label={`Move ${r.name} up`} disabled={i === 0} onClick={() => reorderRound(i, -1)}><ArrowUp size={14}/></button>
                      <button type="button" aria-label={`Move ${r.name} down`} disabled={i === rounds.length - 1} onClick={() => reorderRound(i, 1)}><ArrowDown size={14}/></button>
                    </div>}
                    <span style={{
                      fontSize:12, fontWeight:600, borderRadius:6, padding:'4px 10px', letterSpacing:'.04em', textTransform:'uppercase', fontFamily:'var(--font-mono)',
                      background: isActive?'var(--green-s)':isLocked?'var(--bg-2)':'var(--amber-s)',
                      color: isActive?'var(--green)':isLocked?'var(--muted)':'var(--amber)',
                      border:`1px solid ${isActive?'var(--green)':isLocked?'var(--line)':'var(--amber)'}`,
                    }}>
                      {isLocked ? 'Locked' : isActive ? 'Active' : r.status}
                    </span>
                    </div>
                  </div>
                  <div style={{ display:'flex', gap:24, fontSize:14, color:'var(--muted)' }}>
                    <span>{ev.teams?.length || 0} teams</span>
                    <span>{judgeProgress.completed}/{judgeProgress.total} assigned judge{judgeProgress.total!==1?'s':''} complete</span>
                    <span>{r.advance_count ? `${r.advance_count} shortlisted` : 'Not shortlisted yet'}</span>
                  </div>
                  {isActive && (
                    <div style={{ marginTop:16 }}>
                      <Btn size="sm" variant="danger" onClick={()=>setConfirmLockId(r.id)}>
                        <Lock size={14} /> Lock Round
                      </Btn>
                    </div>
                  )}
                </div>
              );
            })}
          </Card>
        </Motion>
      )}
      <ConfirmModal
        isOpen={!!confirmLockId}
        title="Lock Round"
        desc="Are you sure you want to lock this round? Judges will no longer be able to submit scores for it."
        danger confirmText="Lock Round"
        onCancel={()=>setConfirmLockId(null)}
        onConfirm={async ()=>{ 
          try {
            const { error } = await supabase.rpc('close_event_round', {
              target_event_id: ev.id,
              target_round_id: confirmLockId,
            });
            if (error) throw error;
            await queryClient.invalidateQueries({ queryKey: ['eventData'] });
            toast('Round locked');
          } catch(e) { toast(e.message || 'Failed to lock round'); }
          setConfirmLockId(null); 
        }}
      />
    </div>
  );
}

/* ── RESULTS ─────────────────────────────────────────── */
export function ResultsTab() {
  const { data: ev } = useEventData();
  const queryClient = useQueryClient();
  const rounds = sortedRounds(ev);
  const [roundId, setRoundId] = useState(null);
  const [expanded, setExpanded] = useState(null);
  const [overrideForm, setOverrideForm] = useState({ amount: '', justification: '' });
  const [savingOverride, setSavingOverride] = useState(false);
  const [sortBy, setSortBy] = useState('round'); // 'round' or 'overall'

  // Reset override form whenever the user opens a different team row
  useEffect(() => {
    setOverrideForm({ amount: '', justification: '' });
  }, [expanded]);

  if (!rounds.length) return (
    <div style={{ paddingTop:48 }}>
      <Empty icon={BarChart2} title="No rounds started yet" sub="Start a round from the Rounds tab" />
    </div>
  );

  const defaultRound = rounds.find(r => r.status === 'live') || rounds.find(r => r.status === 'upcoming') || rounds[rounds.length-1];
  const round = rounds.find(r => r.id === roundId) || defaultRound;
  if (!round) return null;

  // If a round is closed and has advance_count, maybe it filters teams? The schema doesn't specify explicitly.
  // We'll show all teams, but highlight if they are in top N.
  const teams = ev.teams || [];
  
  const sorted = [...teams].sort((a,b) => {
    const scoreA = sortBy === 'overall' ? getOverallAvg(ev, a.id) : getAvg(ev, round.id, a.id);
    const scoreB = sortBy === 'overall' ? getOverallAvg(ev, b.id) : getAvg(ev, round.id, b.id);
    return compareScoreRows(scoreA, a, scoreB, b);
  });

  const rankStyle = i => {
    if (i===0) return { background:'var(--amber-s)', color:'var(--amber)', border:'1px solid var(--amber)' };
    if (i===1) return { background:'var(--bg-2)', color:'var(--muted-2)', border:'1px solid var(--line)' };
    if (i===2) return { background:'var(--bg-2)', color:'var(--muted-2)', border:'1px solid var(--line)' };
    return { background:'var(--bg-2)', color:'var(--muted-2)', border:'1px solid var(--line)' };
  };

  return (
    <div style={{ paddingTop:24 }}>
      <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', marginBottom: 16 }}>
        <ChipRow items={rounds.map(r=>({ id:r.id, label:`Round ${r.number}` }))} active={round.id} onSelect={id=>{ setRoundId(id); setExpanded(null); }} />
        <div style={{ display: 'flex', gap: 12 }}>
          <div style={{ display:'flex', alignItems:'center', gap: 8, background: 'var(--panel-2)', padding: 6, borderRadius: 'var(--radius-full)' }}>
            <button onClick={() => setSortBy('round')} className="hover-lift" style={{ padding: '6px 16px', fontSize: 13, fontWeight: 600, borderRadius: 'var(--radius-full)', border: 'none', background: sortBy === 'round' ? 'var(--ink)' : 'transparent', color: sortBy === 'round' ? 'var(--bg)' : 'var(--muted)', cursor: 'pointer', transition: 'all .2s', boxShadow: sortBy==='round'?'var(--shadow-sm)':'none' }}>Round Score</button>
            <button onClick={() => setSortBy('overall')} className="hover-lift" style={{ padding: '6px 16px', fontSize: 13, fontWeight: 600, borderRadius: 'var(--radius-full)', border: 'none', background: sortBy === 'overall' ? 'var(--ink)' : 'transparent', color: sortBy === 'overall' ? 'var(--bg)' : 'var(--muted)', cursor: 'pointer', transition: 'all .2s', boxShadow: sortBy==='overall'?'var(--shadow-sm)':'none' }}>Average Across Scored Rounds</button>
          </div>
          <Btn size="sm" variant="ghost" onClick={() => {
            const prev = document.title;
            document.title = `${ev.name} - Official Report`;
            window.print();
            document.title = prev;
          }}><Printer size={16} /> Export PDF</Btn>
        </div>
      </div>
      <Motion type="scaleIn">
        <Card>
          <SectionHead title="Scoreboard" sub={`Round ${round.number} · ${teams.length} teams · Click a row to expand judge breakdown`} />
          {sorted.length===0 && <Empty icon={BarChart2} title="No teams yet" sub="Add teams to see them on the scoreboard" />}
          {sorted.map((t,i) => {
            const avg = sortBy === 'overall' ? getOverallAvg(ev, t.id) : getAvg(ev, round.id, t.id);
            const track = ev.tracks?.find(tr=>tr.id===t.track_id);
            // We highlight if they are within advance_count
            const isShortlisted = avg !== null && round.advance_count && i < round.advance_count;
            const isExp = expanded===t.id;
            
            // Check for ties
            const isTied = avg !== null && sorted.some(other => other.id !== t.id && (sortBy === 'overall' ? getOverallAvg(ev, other.id) : getAvg(ev, round.id, other.id)) === avg);
            
            // Layout animation for rank change (300ms ease-out)
            const style = {
              background: isShortlisted ? 'var(--green-s)' : isExp ? 'var(--panel-2)' : 'var(--panel)',
              border:`1px solid ${isShortlisted?'var(--green)':isExp?'var(--ink)':'var(--line)'}`,
              borderRadius:'var(--radius-md)', padding:'16px 20px', marginBottom:12,
              cursor:'pointer', transition:'all 300ms cubic-bezier(0, 0, 0.2, 1)',
              boxShadow: isExp ? 'var(--shadow-sm)' : 'none'
            };
            
            return (
              <div key={t.id} onClick={()=>setExpanded(isExp?null:t.id)}
                style={style} className="hover-lift"
                onMouseEnter={e=>{ if(!isShortlisted&&!isExp){e.currentTarget.style.borderColor='var(--ink)';e.currentTarget.style.background='var(--panel-2)'; }}}
                onMouseLeave={e=>{ if(!isShortlisted&&!isExp){e.currentTarget.style.borderColor='var(--line)';e.currentTarget.style.background='var(--panel)'; }}}
              >
                <div style={{ display:'flex', alignItems:'center', gap:16 }}>
                  <div className={i===0 ? "rank-1-gradient" : ""} style={{ width:40, height:40, borderRadius:8, flexShrink:0, display:'flex', alignItems:'center', justifyContent:'center', fontSize:16, fontWeight:700, fontFamily:'var(--font-mono)', ...rankStyle(i) }}>
                    {competitionRank(sorted, i, team => sortBy === 'overall' ? getOverallAvg(ev, team.id) : getAvg(ev, round.id, team.id)) ?? '—'}
                  </div>
                  <div style={{ flex:1, minWidth:0 }}>
                    <div style={{ display:'flex', alignItems:'center', gap:12, flexWrap:'wrap' }}>
                      <span style={{ fontFamily:'var(--font-display)', fontSize:18, fontWeight:600, color:'var(--ink)', letterSpacing:'-.01em' }}>{t.name}</span>
                      {t.projectTitle && <span style={{ fontSize:15, color:'var(--muted)', fontFamily:'var(--font-body)' }}>{t.projectTitle}</span>}
                      {track && <span style={{ fontSize:12, fontWeight:600, color:'var(--bg)', background:'var(--ink)', border:'1px solid var(--ink)', borderRadius:'var(--radius-full)', padding:'2px 8px', fontFamily:'var(--font-mono)' }}>{track.name}</span>}
                      
                      {/* Coverage Badge */}
                      {(() => {
                        const assignedJudges = getAssignedJudges(ev, round.id, t);
                        const completedJudges = assignedJudges.filter(j => isJudgeComplete(ev, round.id, j.id, t.id)).length;
                        const isComplete = assignedJudges.length > 0 && completedJudges === assignedJudges.length;
                        return (
                          <Tooltip text={`Assigned judges with all active criteria scored (${completedJudges}/${assignedJudges.length})`}>
                            <span style={{ cursor: 'help', fontSize:12, fontWeight:600, color: isComplete?'var(--green)':'var(--amber)', background: isComplete?'var(--green-s)':'var(--amber-s)', border:`1px solid ${isComplete?'var(--green)':'var(--amber)'}`, borderRadius:6, padding:'2px 8px', fontFamily:'var(--font-mono)' }}>
                              {completedJudges}/{assignedJudges.length} Complete
                            </span>
                          </Tooltip>
                        );
                      })()}

                      {isShortlisted && <span style={{ fontSize:12, fontWeight:600, color:'var(--green)', background:'var(--green-s)', border:'1px solid var(--green)', borderRadius:6, padding:'2px 8px', fontFamily:'var(--font-mono)' }}>Advanced</span>}
                      {isTied && (
                        <Tooltip text="This team shares the exact same score with another team.">
                          <span style={{ cursor: 'help', fontSize:12, fontWeight:600, color:'var(--amber)', background:'var(--amber-s)', border:'1px solid var(--amber)', borderRadius:6, padding:'2px 8px', fontFamily:'var(--font-mono)' }}>Tied</span>
                        </Tooltip>
                      )}
                    </div>
                    <div style={{ fontSize:14, color:'var(--muted)', marginTop:4 }}>{isExp?'Click to collapse':'Click to see judge breakdown'}</div>
                  </div>
                  <div style={{ flexShrink:0, display:'flex', flexDirection:'column', alignItems:'flex-end' }}>
                    <Tooltip text={sortBy === 'overall' ? "Equal average of this team's recorded round results. Teams can have different numbers of recorded rounds." : "Average score for this round"}>
                      <div><SplitFlapDigit value={avg} size="M" /></div>
                    </Tooltip>
                    {sortBy === 'overall' && <div style={{ fontSize:11, color:'var(--muted)', marginTop:4, textTransform:'uppercase', fontWeight:600 }}>{sortedRounds(ev).filter(item => getAvg(ev, item.id, t.id) !== null).length} of {rounds.length} rounds</div>}
                  </div>
                </div>
                {isExp && (
                  <div style={{ marginTop:16, paddingTop:16, borderTop:'1px solid var(--line)' }}>
                    {getAssignedJudges(ev, round.id, t).map(j => {
                      const total = getJudgeTotal(ev, round.id, j.id, t.id);
                      const hasScored = isJudgeComplete(ev, round.id, j.id, t.id);
                      return (
                        <div key={j.id} style={{ display:'flex', justifyContent:'space-between', padding:'8px 0', fontSize:14, borderBottom:'1px solid var(--line)' }}>
                          <span style={{ color:'var(--muted)' }}>{j.name}</span>
                          <span style={{ color:hasScored?'var(--ink)':'var(--muted)', fontWeight:hasScored?600:400, fontFamily:'var(--font-mono)' }}>{hasScored?total:'—'}</span>
                        </div>
                      );
                    })}
                    
                    {/* Manual Override UI */}
                    <div onClick={event => event.stopPropagation()} style={{ marginTop: 24, padding: 16, background: 'var(--bg)', borderRadius: 8, border: '1px solid var(--line)' }}>
                      <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--ink)', marginBottom: 12 }}>Audited Score Adjustment</div>
                      <div style={{ display: 'flex', gap: 12, marginBottom: 12 }}>
                        <Input type="number" min="-10" max="10" step="0.1" placeholder="+/- points" value={overrideForm.amount} onChange={e => setOverrideForm(f => ({ ...f, amount: e.target.value }))} style={{ width: 150 }} />
                        <Input placeholder="Audit justification (required)" value={overrideForm.justification} onChange={e => setOverrideForm(f => ({ ...f, justification: e.target.value }))} style={{ flex: 1 }} />
                      </div>
                      <Btn size="sm" disabled={savingOverride || !overrideForm.amount || !Number.isFinite(Number(overrideForm.amount)) || Math.abs(Number(overrideForm.amount)) > 10 || !overrideForm.justification.trim()} onClick={async () => {
                        if (savingOverride) return;
                        setSavingOverride(true);
                        const amount = Number(overrideForm.amount);
                        try {
                          const { data: savedOverride, error } = await supabase.from('overrides').insert({
                            event_id: ev.id,
                            round_id: round.id,
                            team_ids: [t.id],
                            amount,
                            resolved_by: ev.organizer_id,
                            resolution_note: overrideForm.justification
                          }).select().single();
                          if (error) throw error;

                          const queryKey = ['eventData', ev.organizer_id];
                          queryClient.setQueryData(queryKey, current => {
                            if (!current) return current;
                            const currentResult = current.team_round_results?.find(result => result.round_id === round.id && result.team_id === t.id);
                            const nextResult = currentResult
                              ? {
                                  ...currentResult,
                                  score: (currentResult.has_result ? Number(currentResult.score) || 0 : 0) + amount,
                                  adjustment: (Number(currentResult.adjustment) || 0) + amount,
                                  has_result: true,
                                }
                              : {
                                  event_id: ev.id,
                                  round_id: round.id,
                                  team_id: t.id,
                                  score: amount,
                                  completed_judge_count: 0,
                                  applicable_criterion_count: 0,
                                  adjustment: amount,
                                  has_result: true,
                                };
                            return {
                              ...current,
                              overrides: [...(current.overrides || []), savedOverride],
                              team_round_results: currentResult
                                ? current.team_round_results.map(result => result === currentResult ? nextResult : result)
                                : [...(current.team_round_results || []), nextResult],
                            };
                          });
                          toast('Score adjustment applied and recorded');
                          setOverrideForm({ amount: '', justification: '' });
                          void queryClient.invalidateQueries({ queryKey }).catch(error => {
                            console.error('[HackJudge] Could not refresh score adjustment:', error);
                          });
                        } catch(e) {
                          toast(e.message || 'Could not save score adjustment');
                        } finally {
                          setSavingOverride(false);
                        }
                      }}>Apply Adjustment</Btn>

                      {(ev.overrides || []).filter(row => row.round_id === round.id && row.team_ids?.includes(t.id)).map(row => (
                        <div key={row.id} style={{ marginTop: 10, fontSize: 12, color: 'var(--muted)' }}>
                          {Number(row.amount) > 0 ? '+' : ''}{Number(row.amount).toFixed(2)} points · {row.resolution_note} · {new Date(row.resolved_at).toLocaleString()}
                        </div>
                      ))}
                      
                      {/* Read overrides for this team */}
                    </div>
                  </div>
                )}
              </div>
            );
          })}
        </Card>
      </Motion>
      <ReportTemplate ev={ev} />
    </div>
  );
}

/* ── SHORTLIST ────────────────────────────────────────── */
export function ShortlistTab() {
  const { data: ev } = useEventData();
  const queryClient = useQueryClient();
  const rounds = sortedRounds(ev);
  const [roundId, setRoundId] = useState(null);
  const [mode, setMode] = useState('topN');
  const [topN, setTopN] = useState(10);
  const [cutoff, setCutoff] = useState(50);
  const [manual, setManual] = useState({});

  if (!rounds.length) return (
    <div style={{ paddingTop:48 }}>
      <Empty icon={CheckSquare} title="No rounds yet" sub="Start and complete a round first" />
    </div>
  );

  const defaultRound = rounds.find(r => r.status === 'live') || rounds.find(r => r.status === 'upcoming') || rounds[rounds.length-1];
  const round = rounds.find(r => r.id === roundId) || defaultRound;
  if (!round) return null;

  const teams = ev.teams || [];
  const sorted = [...teams].sort((a,b)=>compareScoreRows(getAvg(ev, round.id, a.id), a, getAvg(ev, round.id, b.id), b));

  function preview() {
    if (mode==='topN') {
      const ranked = sorted.filter(team => getAvg(ev, round.id, team.id) !== null);
      const limit = Math.max(0, Math.min(ranked.length, Math.floor(Number(topN) || 0)));
      if (!limit) return [];
      const boundaryScore = getAvg(ev, round.id, ranked[limit - 1].id);
      return ranked.filter(team => getAvg(ev, round.id, team.id) >= boundaryScore).map(team => team.id);
    }
    if (mode==='cutoff') return sorted.filter(t=>getAvg(ev,round.id,t.id) !== null && getAvg(ev,round.id,t.id)>=cutoff).map(t=>t.id);
    return Object.keys(manual).filter(id=>manual[id]);
  }
  const selected = preview();

  const modeStyle = m => ({
    padding:'10px 20px', borderRadius:'var(--radius-full)', fontSize:14, fontWeight:600,
    cursor:'pointer', fontFamily:'var(--font-body)', transition:'all .2s ease',
    background: mode===m ? 'var(--ink)' : 'var(--panel-2)',
    color: mode===m ? 'var(--bg)' : 'var(--muted)',
    border:`1px solid ${mode===m ? 'transparent' : 'var(--line)'}`,
    boxShadow: mode===m ? 'var(--shadow-sm)' : 'none'
  });

  const numInput = { width:80, textAlign:'center', background:'var(--panel-2)', border:'1px solid var(--line)', borderRadius:'var(--radius-md)', padding:'10px', color:'var(--ink)', fontSize:16, outline:'none', fontFamily:'var(--font-mono)', transition: 'all .2s ease' };

  return (
    <div style={{ display:'flex', flexDirection:'column', gap:22, paddingTop:24 }}>
      <ChipRow items={rounds.map(r=>({ id:r.id, label:`Round ${r.number}` }))} active={round.id} onSelect={id=>{ setRoundId(id); setManual({}); }} />

      <Motion type="fadeUp">
        <Card>
          <SectionHead title="Shortlisting Method" sub="Choose how teams advance to the next round" />
          <div style={{ display:'flex', gap:10, flexWrap:'wrap', marginBottom:24 }}>
            <button style={modeStyle('topN')}   onClick={()=>setMode('topN')}>Top N</button>
            <button style={modeStyle('cutoff')} onClick={()=>setMode('cutoff')}>Score Cutoff</button>
            <button style={modeStyle('manual')} onClick={()=>setMode('manual')}>Manual</button>
          </div>

          {mode==='topN' && (
            <div style={{ display:'flex', alignItems:'center', gap:14, flexWrap:'wrap' }}>
              <span style={{ fontSize:14, color:'var(--ink)' }}>Shortlist the top</span>
              <input type="number" value={topN} min={1} max={teams.length} onChange={e=>setTopN(+e.target.value)} style={numInput} />
              <span style={{ fontSize:14, color:'var(--ink)' }}>of {teams.length} teams</span>
            </div>
          )}

          {mode==='cutoff' && (
            <div style={{ display:'flex', alignItems:'center', gap:14, flexWrap:'wrap' }}>
              <span style={{ fontSize:14, color:'var(--ink)' }}>Minimum average score ≥</span>
              <input type="number" value={cutoff} min={0} onChange={e=>setCutoff(+e.target.value)} style={numInput} />
            </div>
          )}

          {mode==='manual' && (
            <div style={{ display:'flex', flexDirection:'column', gap:8 }}>
              <p style={{ fontSize:14, color:'var(--muted)', marginBottom:8 }}>Toggle teams individually</p>
              {sorted.map(t => (
                <label key={t.id} className="hover-lift" style={{
                  display:'flex', alignItems:'center', gap:16, padding:'14px 16px',
                  borderRadius:'var(--radius-md)', cursor:'pointer',
                  border:`1px solid ${manual[t.id]?'var(--ink)':'var(--line)'}`,
                  background: manual[t.id]?'var(--panel)':'var(--panel-2)',
                  boxShadow: manual[t.id]?'var(--shadow-sm)':'none',
                  transition:'all .2s ease',
                }}>
                  <input type="checkbox" checked={!!manual[t.id]} onChange={e=>setManual(m=>({...m,[t.id]:e.target.checked}))} style={{ accentColor:'var(--ink)', width:20, height:20, cursor:'pointer' }} />
                  <div style={{ flex:1, display:'flex', flexDirection:'column' }}>
                    <span style={{ fontSize:16, fontWeight:600, fontFamily:'var(--font-display)' }}>{t.name}</span>
                    {t.projectTitle && <span style={{ fontSize:14, color:'var(--muted)', marginTop:2 }}>{t.projectTitle}</span>}
                  </div>
                  <SplitFlapDigit value={getAvg(ev,round.id,t.id)} size="S" />
                </label>
              ))}
            </div>
          )}
        </Card>
      </Motion>

      <Motion delay={1} type="fadeUp">
        <Card>
          <SectionHead title="Preview" sub={`${selected.length} of ${teams.length} teams will advance`} />
          <div style={{ marginBottom:24 }}>
            {sorted.map((t,i) => {
              const inList = selected.includes(t.id);
              return (
                <div key={t.id} style={{
                  display:'flex', alignItems:'center', justifyContent:'space-between',
                  padding:'16px', borderRadius:8, marginBottom:10,
                  border:`1px solid ${inList?'var(--green)':'var(--line)'}`,
                  background: inList?'var(--green-s)':'var(--panel-2)',
                  opacity: inList?1:.45, transition:'all .25s ease',
                }}>
                  <div style={{ display:'flex', alignItems:'center', gap:12 }}>
                    <span style={{ fontSize:14, color:'var(--muted)', width:24, textAlign:'center', fontFamily:'var(--font-mono)' }}>#{i+1}</span>
                    <div style={{ display:'flex', flexDirection:'column' }}>
                      <span style={{ fontSize:16, fontWeight:600, fontFamily:'var(--font-display)', color:inList?'var(--ink)':'var(--muted)' }}>{t.name}</span>
                      {t.projectTitle && <span style={{ fontSize:14, color:'var(--muted)', marginTop:2 }}>{t.projectTitle}</span>}
                    </div>
                    {inList && <span style={{ fontSize:14, color:'var(--green)', fontWeight:700 }}>✓</span>}
                  </div>
                  <span style={{ fontFamily:'var(--font-mono)', fontSize:20, fontWeight:600, color:inList?'var(--green)':'var(--muted)' }}>{getAvg(ev,round.id,t.id)}</span>
                </div>
              );
            })}
          </div>
          <Btn full variant="success" disabled={selected.length===0} onClick={async () => {
            try {
              const { error } = await supabase.rpc('finalize_event_shortlist', {
                target_event_id: ev.id,
                target_round_id: round.id,
                selected_team_ids: selected,
              });
              if (error) throw error;
              await queryClient.invalidateQueries({ queryKey: ['eventData'] });
              toast(`${selected.length} teams confirmed for next round`);
            } catch(e) { toast(e.message || 'Error updating round'); }
          }}>
            <CheckSquare size={15} /> Confirm — {selected.length} teams advance
          </Btn>
          {round.advance_count && (
            <p style={{ textAlign:'center', fontSize:12, color:'var(--muted)', marginTop:12 }}>
              Previously: {round.advance_count} teams advanced. Confirming will overwrite.
            </p>
          )}
        </Card>
      </Motion>
    </div>
  );
}
