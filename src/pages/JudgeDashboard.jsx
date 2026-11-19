import { useState, useRef } from 'react';
import { ChevronLeft, ChevronRight, Check } from 'lucide-react';
import { Topbar } from '../components/Topbar';
import { Btn, Badge, Empty, Alert, ProgressBar, Motion, SplitFlapDigit } from '../components/ui';
import { toast } from '../lib/toast';
import { useJudgeData, useJudgeMutate } from '../hooks/useJudgeData.jsx';
import { useAuth } from '../hooks/useAuth.jsx';
import { uid } from '../security';
import { calculateWeightedTotal, isScorableCriterion, sortedRounds } from '../utils/scoring.js';

export default function JudgeDashboard() {
  const { data, isLoading, error } = useJudgeData();
  const { claimAccount } = useJudgeMutate();
  const { user, signOut } = useAuth(); // MUST be called unconditionally before any early returns
  const [view, setView] = useState('list');
  const [teamIdx, setTeamIdx] = useState(0);
  const [transitioning, setTransitioning] = useState(false);

  if (isLoading) return <div style={{ minHeight:'100vh', display:'flex', alignItems:'center', justifyContent:'center', color:'var(--muted)' }}>Loading your dashboard...</div>;
  if (error || !data) return <div style={{ minHeight:'100vh', display:'flex', alignItems:'center', justifyContent:'center', color:'var(--amber)' }}>Error loading dashboard. Please log in again.</div>;

  const { event: ev, judge } = data;
  const rawScores = data.scores || [];
  if (judge.user_id === null && user?.email) return (
    <div style={{ minHeight:'100vh', display:'flex', flexDirection:'column', background:'var(--bg)' }}>
      <Topbar title={ev.name} sub={`Judge: ${judge.name}`} onLogout={signOut} />
      <div style={{ flex:1, display:'flex', alignItems:'center', justifyContent:'center', padding:24 }}>
        <Motion type="scaleIn">
          <div style={{ background:'var(--panel)', padding:32, borderRadius:16, boxShadow:'0 20px 40px rgba(0,0,0,0.2)', maxWidth:440, textAlign:'center', border:'1px solid var(--line)' }}>
            <h2 style={{ fontSize:24, fontWeight:700, marginBottom:12, fontFamily:'var(--font-display)', color:'var(--ink)' }}>Claim Your Judge Account</h2>
            <p style={{ fontSize:16, color:'var(--muted)', marginBottom:24, lineHeight:1.5 }}>
              This assignment was created for {judge.email}. Claim it to link your verified account and continue to the judging dashboard.
            </p>
            <Btn full size="lg" disabled={claimAccount.isPending} onClick={() => {
              claimAccount.mutate(judge.id, {
                onSuccess: () => toast('Account claimed successfully!'),
                onError: (e) => toast('Error claiming account: ' + e.message)
              });
            }}>
              {claimAccount.isPending ? 'Claiming...' : 'Claim Account & Continue'}
            </Btn>
          </div>
        </Motion>
      </div>
    </div>
  );
  const rounds = sortedRounds(data); // Ensures rounds have .number
  
  // Active round is the latest one that is 'live'
  const round = [...rounds].reverse().find(r => r.status === 'live');
  const roundIndex = round ? rounds.findIndex(r => r.id === round.id) : -1;
  const prevRound = roundIndex > 0 ? rounds[roundIndex - 1] : null;

  // Filter teams to only those shortlisted in the previous round (if applicable)
  const teams = (data.teams || []).filter(t => {
    if (!prevRound || prevRound.advanced_team_ids == null) return true;
    return prevRound.advanced_team_ids.includes(t.id);
  });

  if (!round) return (
    <div style={{ minHeight:'100vh', background:'var(--bg)', display:'flex', flexDirection:'column' }}>
      <Topbar title={ev.name} sub={`Judge: ${judge?.name}`} onLogout={signOut} />
      <div style={{ flex:1, display:'flex', flexDirection:'column', alignItems:'center', justifyContent:'center', padding:48, textAlign:'center', gap:20 }}>
        <div style={{ width:56, height:56, borderRadius:14, background:'var(--amber-s)', border:'1px solid var(--amber)', display:'flex', alignItems:'center', justifyContent:'center' }}>
          <div className="pulse-once" style={{ width:22, height:22, borderRadius:'50%' }} />
        </div>
        <div>
          <h2 style={{ fontFamily:'var(--font-display)', fontSize:24, marginBottom:8, color:'var(--ink)', fontWeight:600 }}>Waiting for a round</h2>
          <p style={{ fontSize:16, color:'var(--muted)', lineHeight:1.5 }}>The organiser hasn't started a round yet.<br />Please wait and check back shortly.</p>
        </div>
      </div>
    </div>
  );


  // Format raw scores for easy lookup
  const parsedScores = {};
  teams.forEach(t => {
    parsedScores[t.id] = {};
    const teamScores = rawScores.filter(s => s.team_id === t.id && s.round_id === round?.id);
    // Use the database-generated revision order, never client-provided timestamps.
    teamScores.sort((a,b) => Number(a.revision) - Number(b.revision));
    teamScores.forEach(s => {
      parsedScores[t.id][s.criterion_id] = s.value;
    });
  });

  // Event metadata and its related criteria are separate fields in useJudgeData.
  const activeCriteria = (data.criteria || []).filter(c => isScorableCriterion(c) && (c.round_ids?.length === 0 || c.round_ids?.includes(round.id)));
  const scoredCount = teams.filter(t => activeCriteria.length > 0 && activeCriteria.every(c => parsedScores[t.id][c.id] !== undefined && parsedScores[t.id][c.id] !== null)).length;
  const pct = teams.length ? (scoredCount/teams.length)*100 : 0;
  
  return (
    <div style={{ minHeight:'100vh', display:'flex', flexDirection:'column', background:'var(--bg)' }}>
      <Topbar
        title={ev.name}
        sub={`Judge: ${judge?.name}`}
        right={
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <Badge variant={round.status==='live'?'teal':'default'}>Round {round.number || 1}</Badge>
          </div>
        }
        onLogout={signOut}
      />
      
      {/* Sparsity requirement for judge - removed progress bar background, made it float slightly */}
      <div className="judge-progress" style={{ padding:'16px 24px' }}>
        <ProgressBar pct={pct} label={`${scoredCount} of ${teams.length} teams scored`} />
      </div>
      
      <div style={{ flex:1, display:'flex', flexDirection:'column', overflow:'hidden', position:'relative' }}>
        {view==='list'
          ? <TeamList ev={data} round={round} teams={teams} parsedScores={parsedScores} onSelect={i=>{ setTeamIdx(i); setView('score'); }} />
          : <div className={transitioning ? 'slide-left-out' : 'tab-enter'} style={{ flex:1, display:'flex', flexDirection:'column', overflow:'hidden', width:'100%', height:'100%' }}>
              <ScoringView data={data} round={round} judge={judge} teams={teams} teamIdx={teamIdx} parsedScores={parsedScores}
                setTeamIdx={setTeamIdx} setView={setView} setTransitioning={setTransitioning}
              />
            </div>
        }
      </div>
    </div>
  );
}

/* ── TEAM LIST ───────────────────────────────────────── */
function TeamList({ ev, round, teams, parsedScores, onSelect }) {
  const activeCriteria = ev.criteria.filter(c => isScorableCriterion(c) && (c.round_ids?.length === 0 || c.round_ids?.includes(round.id)));
  const isComplete = team => activeCriteria.length > 0 && activeCriteria.every(c => parsedScores[team.id][c.id] !== undefined && parsedScores[team.id][c.id] !== null);
  const allDone = teams.length > 0 && teams.every(isComplete);

  return (
    <div className="judge-team-list tab-enter" style={{ flex:1, overflowY:'auto', padding:'24px' }}>
      {round.status==='closed' && <Alert variant="warn" style={{ marginBottom:24 }}>This round is locked — scores are final.</Alert>}
      {allDone && round.status !== 'closed' && (
        <Motion type="fadeIn">
          <Alert variant="success">All teams scored. You can still edit any score until the organiser locks this round.</Alert>
        </Motion>
      )}
      {teams.map((t,i) => {
        const scores = parsedScores[t.id];
        const hasScored = isComplete(t);
        const track = ev.tracks.find(tr=>tr.id===t.track_id);
        const total = hasScored ? calculateWeightedTotal(activeCriteria, scores) : 0;
        
        return (
          <Motion key={t.id} delay={i%12} type="fadeUp">
            <div onClick={()=>onSelect(i)}
              style={{
                display:'flex', alignItems:'center', gap:16,
                background: 'var(--panel)',
                border:`1px solid ${hasScored?'var(--green)':'var(--line)'}`,
                borderRadius:14, padding:'20px 24px', marginBottom:12,
                cursor:'pointer', transition:'all .15s ease',
              }}
              onMouseEnter={e=>{ e.currentTarget.style.background='var(--panel-2)'; }}
              onMouseLeave={e=>{ e.currentTarget.style.background='var(--panel)'; }}>

              {/* status indicator */}
              <div style={{
                width:12, height:12, borderRadius:'50%', flexShrink:0,
                background: hasScored?'var(--green)':'var(--line)',
                transition:'background .15s ease',
              }} />

              <div style={{ flex:1, minWidth:0 }}>
                <div style={{ fontFamily:'var(--font-display)', fontSize:18, fontWeight:600, color:'var(--ink)', letterSpacing:'-.01em', whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis' }}>{t.name}</div>
                {t.projectTitle && <div style={{ fontSize:14, color:'var(--muted)', marginTop:2, whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis' }}>{t.projectTitle}</div>}
                <div style={{ fontSize:14, color:'var(--muted)', marginTop:t.projectTitle?2:4 }}>
                  {track?`${track.name} · `:''}
                  {hasScored ? 'Scored — tap to review' : 'Tap to score'}
                </div>
              </div>
              <div style={{ display:'flex', alignItems:'center', gap:16, flexShrink:0 }}>
                {hasScored && <span style={{ fontFamily:'var(--font-mono)', fontSize:24, fontWeight:700, color:'var(--ink)', lineHeight:1 }}>{total.toFixed(0)}</span>}
                <ChevronRight size={20} style={{ color:'var(--muted)' }} />
              </div>
            </div>
          </Motion>
        );
      })}
      {teams.length===0 && <Empty icon={null} title="No teams in this round" sub="The organiser hasn't added teams yet" />}
    </div>
  );
}

/* ── SCORING VIEW ────────────────────────────────────── */
function ScoringView({ data, round, judge, teams, teamIdx, parsedScores, setTeamIdx, setView, setTransitioning }) {
  const team = teams[teamIdx];
  const isLocked = round.status==='closed';
  const existingScores = parsedScores[team?.id] || {};
  const hasExistingScore = Object.keys(existingScores).length > 0;
  const { submitScore } = useJudgeMutate();

  const activeCriteria = data.criteria.filter(c => isScorableCriterion(c) && (c.round_ids?.length === 0 || c.round_ids?.includes(round.id)));

  const initScores = () => {
    const init = {};
    activeCriteria.forEach(p => {
      init[p.id] = existingScores[p.id] !== undefined ? existingScores[p.id] : 0;
    });
    return init;
  };

  const [scores, setScores] = useState(initScores);
  const [submitState, setSubmitState] = useState('idle'); // idle -> flash -> hold -> done
  const prevTeamId = useRef(team?.id);

  // reset state when team changes
  if (prevTeamId.current !== team?.id) {
    prevTeamId.current = team?.id;
    const fresh = initScores();
    setScores(fresh);
    setSubmitState('idle');
  }

  if (!team) { setView('list'); return null; }

  const set = (paramId, val) => { if (isLocked) return; setScores(s=>({...s,[paramId]:val})); setSubmitState('idle'); };

  async function handleSaveSequence() {
    if (isLocked || submitScore.isPending) return;
    
    // 1. Flash to green over 200ms
    setSubmitState('flash');
    
    // Prepare rows for insertion
    const scoreRows = activeCriteria.map(p => ({
      client_id: uid(),
      team_id: team.id,
      round_id: round.id,
      judge_id: judge.id,
      criterion_id: p.id,
      value: Number(scores[p.id] || 0)
    }));

    try {
      await submitScore.mutateAsync(scoreRows);
      await new Promise(resolve => setTimeout(resolve, 250));
      setSubmitState('hold');
      
      // If there's a next unscored team or just next team, auto-advance
      if (teamIdx < teams.length - 1) {
        setTransitioning(true);
        setTimeout(() => {
          setTeamIdx(i => i + 1);
          setTransitioning(false);
        }, 150); // slide-left duration
      } else {
        // if it's the last team, just show done state
        setSubmitState('done');
      }
    } catch (e) {
      toast('Failed to save score: ' + e.message);
      setSubmitState('idle');
    }
  }

  const track = data.tracks.find(t=>t.id===team.track_id);
  const total = calculateWeightedTotal(activeCriteria, scores);

  // Determine card border based on submit sequence
  const cardBorderColor = 
    submitState === 'flash' ? 'var(--green)' :
    submitState === 'hold' ? 'var(--green)' :
    submitState === 'done' ? 'rgba(61, 220, 151, 0.4)' : // subtle green tint
    'var(--line)';

  const cardTransition = 
    submitState === 'flash' ? 'border-color 200ms ease-out' :
    'border-color 150ms ease-in';

  return (
    <div className="judge-score-view" style={{ flex:1, display:'flex', flexDirection:'column', overflow:'hidden' }}>
      {/* team header - sparse */}
      <div style={{ padding:'24px', flexShrink:0 }}>
        <button onClick={()=>setView('list')}
          style={{ fontSize:14, fontWeight:600, color:'var(--muted)', background:'none', border:'none', cursor:'pointer', marginBottom:16, display:'flex', alignItems:'center', gap:8, transition:'color .15s', fontFamily:'var(--font-body)' }}
          onMouseEnter={e=>e.currentTarget.style.color='var(--ink)'}
          onMouseLeave={e=>e.currentTarget.style.color='var(--muted)'}>
          <ChevronLeft size={16} /> All Teams
        </button>
        <div style={{ display:'flex', alignItems:'flex-start', justifyContent:'space-between', gap:16 }}>
          <div>
            <h2 style={{ fontFamily:'var(--font-display)', fontSize:28, color:'var(--ink)', fontWeight:600, letterSpacing:'-.01em', lineHeight:1.1 }}>{team.name}</h2>
            {team.projectTitle && <div style={{ fontSize:16, color:'var(--muted)', marginTop:6, fontFamily:'var(--font-body)', lineHeight:1.3 }}>{team.projectTitle}</div>}
            <div style={{ display:'flex', alignItems:'center', gap:12, marginTop:team.projectTitle?10:10 }}>
              {track && <Badge variant="blue">{track.name}</Badge>}
              <span style={{ fontSize:14, color:'var(--muted)' }}>Team {teamIdx+1} of {teams.length}</span>
            </div>
          </div>
          {/* score total - mono font */}
          <div style={{ textAlign:'right', flexShrink:0 }}>
            <SplitFlapDigit value={total.toFixed(0)} size="L" />
            <div style={{ fontSize:12, fontWeight:600, color:'var(--muted)', textTransform:'uppercase', letterSpacing:'.06em', marginTop:8 }}>points</div>
          </div>
        </div>
      </div>

      {/* parameters - dense enough to not scroll unnecessarily, but touch targets are 44px+ */}
      <div style={{ flex:1, overflowY:'auto', padding:'0 24px 24px' }}>
        {isLocked && <Alert variant="warn">Round is locked — scores cannot be changed.</Alert>}
        
        <div style={{ 
          background:'var(--panel)', border:`2px solid ${cardBorderColor}`, 
          borderRadius:14, padding:'24px', transition:cardTransition 
        }}>
          {activeCriteria.map((p,i) => (
            <div key={p.id} style={{ marginBottom: i===activeCriteria.length-1 ? 0 : 32 }}>
              <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', marginBottom:16 }}>
                <span style={{ fontSize:16, fontWeight:600, color:'var(--ink)' }}>{p.name}</span>
                <span style={{ fontSize:12, fontWeight:600, color:'var(--muted)', textTransform:'uppercase', letterSpacing:'.03em' }}>Numeric</span>
              </div>

              <SliderInput value={Number(scores[p.id]??0)} min={0} max={p.max_score} onChange={v=>set(p.id,v)} disabled={isLocked || submitScore.isPending} />
            </div>
          ))}
        </div>
        <div style={{ height:32 }} />
      </div>

      {/* footer actions - sticky submit button floating */}
      <div style={{ padding:'24px', background:'var(--bg)', flexShrink:0, borderTop:'1px solid var(--line)' }}>
        {isLocked
          ? <div style={{ textAlign:'center', fontSize:14, color:'var(--muted)', padding:'8px 0' }}>Round locked — scores are final</div>
          : (
            <div style={{ display:'flex', flexDirection:'column', alignItems:'center' }}>
              <Btn size="lg" full variant={submitState==='done'?'success':'primary'} onClick={handleSaveSequence} disabled={submitScore.isPending}
                   style={{ boxShadow: submitState==='done' ? 'none' : '0 8px 24px rgba(91,127,255,0.2)' }}>
                {submitScore.isPending ? 'Saving...' : submitState === 'done' ? <><Check size={18} /> Score Saved</> : (hasExistingScore ? 'Update Score' : 'Submit Score')}
              </Btn>
            </div>
          )
        }
      </div>
    </div>
  );
}

/* ── PARAM INPUT COMPONENTS ──────────────────────────── */

function SliderInput({ value, min, max, onChange, disabled }) {
  const pct = max>min ? ((value-min)/(max-min))*100 : 0;
  return (
    <div>
      <div style={{ display:'flex', alignItems:'center', gap:24 }}>
        <input type="range" min={min} max={max} value={value}
          style={{ '--pct':`${pct}%`, flex:1 }}
          disabled={disabled}
          onChange={e=>onChange(+e.target.value)}
        />
        <span style={{ fontFamily:'var(--font-mono)', fontSize:28, fontWeight:700, color:'var(--blue)', minWidth:48, textAlign:'right', lineHeight:1 }}>{value}</span>
      </div>
      <div style={{ display:'flex', justifyContent:'space-between', fontSize:14, color:'var(--muted)', marginTop:8 }}>
        <span>{min}</span><span>{max}</span>
      </div>
    </div>
  );
}

