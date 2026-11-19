import { useState, useEffect } from 'react';
import { ArrowLeft, ChevronRight, Plus, Trash2, ArrowUp, ArrowDown } from 'lucide-react';
import { Input, Select, Btn, Card, Motion, Alert } from '../components/ui';
import { toast } from '../lib/toast';
import { supabase } from '../lib/supabase';
import { uid } from '../security.js';

const TEMPLATES = {
  hackathon: [
    { id: uid(), name: 'Innovation', weight: 25 },
    { id: uid(), name: 'Technical Complexity', weight: 25 },
    { id: uid(), name: 'Presentation', weight: 25 },
    { id: uid(), name: 'Business Value/Impact', weight: 25 },
  ],
  pitch_comp: [
    { id: uid(), name: 'Market Size', weight: 25 },
    { id: uid(), name: 'Business Model', weight: 25 },
    { id: uid(), name: 'Team Execution', weight: 25 },
    { id: uid(), name: 'The Ask', weight: 25 },
  ],
  case_comp: [
    { id: uid(), name: 'Analysis Depth', weight: 30 },
    { id: uid(), name: 'Feasibility', weight: 30 },
    { id: uid(), name: 'Presentation', weight: 20 },
    { id: uid(), name: 'Q&A Handling', weight: 20 },
  ],
  other: [
    { id: uid(), name: 'Criterion 1', weight: 100 },
  ]
};

function moveItem(items, index, offset) {
  const target = index + offset;
  if (target < 0 || target >= items.length) return items;
  const next = [...items];
  [next[index], next[target]] = [next[target], next[index]];
  return next;
}

const WIZARD_DRAFT_KEY = 'hackjudge_event_wizard_draft';

function readWizardDraft() {
  try {
    const draft = JSON.parse(sessionStorage.getItem(WIZARD_DRAFT_KEY) || 'null');
    if (draft?.form && Array.isArray(draft.criteria) && Array.isArray(draft.rounds)) return draft;
  } catch {
    // Ignore stale or malformed setup data and start a fresh wizard.
  }
  return null;
}

export default function EventWizard({ onCancel, existingUser }) {
  const [savedDraft] = useState(readWizardDraft);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState('');
  const [step, setStep] = useState(() => {
    const match = window.location.hash.match(/create-step(\d)/);
    return match ? Number(match[1]) : savedDraft ? 3 : 1;
  }); // 1: Basics, 2: Criteria, 3: Rounds

  useEffect(() => {
    const onHash = () => {
      const match = window.location.hash.match(/create-step(\d)/);
      if (match) setStep(Number(match[1]));
      else if (window.location.hash === '#create') setStep(1);
    };
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  const navigateStep = (s) => {
    window.location.hash = `create-step${s}`;
  };

  // Basics
  const [form, setForm] = useState(() => savedDraft?.form || { name: '', type: 'hackathon' });
  
  // Criteria
  const [criteria, setCriteria] = useState(() => savedDraft?.criteria || TEMPLATES['hackathon']);
  
  // Rounds
  const [rounds, setRounds] = useState(() => savedDraft?.rounds || [
    { id: uid(), name: 'Round 1', criteriaIds: [] } // empty criteriaIds means ALL criteria are used
  ]);

  // When event type changes, update criteria template if we haven't manually edited a lot
  const handleTypeChange = (val) => {
    setForm(f => ({ ...f, type: val }));
    // Generate new UIDs for the template items to avoid key collisions
    const newCriteria = TEMPLATES[val].map(c => ({ ...c, id: uid() }));
    setCriteria(newCriteria);
    // Round selections refer to criterion IDs, so refresh them with the new template.
    setRounds(current => current.map(round => ({ ...round, criteriaIds: newCriteria.map(c => c.id) })));
  };

  const addCriterion = () => {
    setCriteria(c => [...c, { id: uid(), name: '', weight: 0 }]);
  };
  
  const removeCriterion = (id) => {
    setCriteria(c => c.filter(x => x.id !== id));
  };
  
  const updateCriterion = (id, key, val) => {
    setCriteria(c => c.map(x => x.id === id ? { ...x, [key]: val } : x));
  };

  const addRound = () => {
    setRounds(r => [...r, { id: uid(), name: `Round ${r.length + 1}`, criteriaIds: criteria.map(c=>c.id) }]);
  };
  
  const removeRound = (id) => {
    if (rounds.length <= 1) return toast('You must have at least one round');
    setRounds(r => r.filter(x => x.id !== id));
  };
  
  const updateRound = (id, key, val) => {
    setRounds(r => r.map(x => x.id === id ? { ...x, [key]: val } : x));
  };
  
  const toggleRoundCriterion = (roundId, critId) => {
    setRounds(r => r.map(round => {
      if (round.id !== roundId) return round;
      let active = round.criteriaIds.length === 0 ? criteria.map(c=>c.id) : round.criteriaIds;
      if (active.includes(critId)) {
        active = active.filter(id => id !== critId);
      } else {
        active = [...active, critId];
      }
      return { ...round, criteriaIds: active };
    }));
  };

  const totalWeight = criteria.reduce((sum, c) => sum + Number(c.weight || 0), 0);
  const isValidWeight = totalWeight === 100;

  const handleNext = () => {
    if (step === 1) {
      if (!form.name) return setErr('Event name is required');
      setErr(''); navigateStep(2);
    } else if (step === 2) {
      if (criteria.some(c => !c.name.trim())) return setErr('All criteria must have names');
      if (!isValidWeight) return setErr(`Weights must sum to 100% (currently ${totalWeight}%)`);
      // Update rounds to use new criteria ids if they were empty
      setRounds(r => r.map(round => round.criteriaIds.length === 0 ? { ...round, criteriaIds: criteria.map(c=>c.id) } : round));
      setErr(''); navigateStep(3);
    }
  };

  const handleSave = async () => {
    if (rounds.some(r => !r.name.trim())) return setErr('All rounds must have names');
    if (rounds.some(r => r.criteriaIds.length === 0)) return setErr('Each round must have at least one criterion');
    const criteriaWithoutRounds = criteria.filter(criterion => !rounds.some(round => {
      const selectedIds = round.criteriaIds.length === 0 ? criteria.map(item => item.id) : round.criteriaIds;
      return selectedIds.includes(criterion.id);
    }));
    if (criteriaWithoutRounds.length) {
      return setErr(`Select at least one round for every criterion: ${criteriaWithoutRounds.map(c => c.name).join(', ')}`);
    }

    setLoading(true);
    setErr('');
    try {
      if (!existingUser) {
        sessionStorage.setItem(WIZARD_DRAFT_KEY, JSON.stringify({ form, criteria, rounds }));
        sessionStorage.setItem('hackjudge_login_intent', 'organizer-create');
        const { error: oauthError } = await supabase.auth.signInWithOAuth({
          provider: 'google',
          options: {
            // Keep the OAuth callback URL fragment-free. Supabase OAuth may
            // use the fragment to return tokens; the saved draft restores the wizard step.
            redirectTo: `${window.location.origin}${window.location.pathname}${window.location.search}`,
          },
        });
        if (oauthError) throw oauthError;
        return;
      }
      const roundRows = rounds.map((r, i) => ({
        id: r.id,
        name: r.name,
        order_index: i,
      }));
      const criteriaRows = criteria.map((c, orderIndex) => {
        // Find which rounds include this criterion
        const mappedRounds = rounds.filter(r => {
          const activeIds = r.criteriaIds.length === 0 ? criteria.map(crit=>crit.id) : r.criteriaIds;
          return activeIds.includes(c.id);
        }).map(r => r.id);

        return {
          id: c.id,
          name: c.name,
          weight: Number(c.weight),
          max_score: 10,
          round_ids: mappedRounds,
          order_index: orderIndex
        };
      });

      const { data: eventId, error: createError } = await supabase.rpc('create_event_setup', {
        new_event_id: uid(),
        event_name: form.name.trim(),
        event_kind: form.type,
        round_data: roundRows,
        criteria_data: criteriaRows,
      });
      if (createError) throw createError;

      toast('Event created successfully!');
      sessionStorage.removeItem(WIZARD_DRAFT_KEY);
      localStorage.setItem('hackjudge_active_event_id', eventId);

      if (existingUser) {
        window.location.hash = '';
        window.location.reload();
      }
    } catch (e) {
      setErr(e.message || 'Failed to save event');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={{ width: '100%', maxWidth: 640, margin: '0 auto', textAlign: 'left' }}>
      <button onClick={onCancel} className="hover-lift back-link" style={{ fontSize:14, fontWeight:600, color:'var(--muted)', marginBottom:16, cursor:'pointer', background:'none', border:'none', display:'inline-flex', alignItems:'center', gap:8 }}>
        <ArrowLeft size={16} aria-hidden="true" />
        <span>Back</span>
      </button>

      <h2 style={{ fontFamily:'var(--font-display)', fontSize:32, fontWeight:600, marginBottom:4, color:'var(--ink)', letterSpacing:'-.02em' }}>
        Create your first event
      </h2>
      <p style={{ fontSize:16, color:'var(--muted)', marginBottom:16, lineHeight:1.6 }}>
        Step {step} of 3: {step === 1 ? 'Basic Details' : step === 2 ? 'Evaluation Criteria' : 'Round Builder'}
      </p>

      {err && <Alert variant="error" style={{ marginBottom: 16 }}>{err}</Alert>}

      {step === 1 && (
        <Motion type="fadeUp">
          <Card className="wizard-card" style={{ padding: '24px' }}>
            <div style={{ display:'flex', flexDirection:'column', gap:16 }}>
              <Input label="Event Name" placeholder="e.g. TechnoVerse 4.0" value={form.name} onChange={e=>setForm(f=>({...f,name:e.target.value}))} />
              <Select label="Event Type" value={form.type} onChange={e=>handleTypeChange(e.target.value)}>
                <option value="hackathon">Hackathon</option>
                <option value="pitch_comp">Pitch Competition</option>
                <option value="case_comp">Case Competition</option>
                <option value="other">Custom</option>
              </Select>
              {!existingUser && <p style={{ color:'var(--muted)', fontSize:14, lineHeight:1.5 }}>You'll sign in with Google when you save the event. Your setup will be kept while you sign in.</p>}
              <Btn size="lg" full onClick={handleNext} style={{ marginTop:8 }}>Next: Configure Criteria <ChevronRight size={18} /></Btn>
            </div>
          </Card>
        </Motion>
      )}

      {step === 2 && (
        <Motion type="fadeUp">
          <Card className="wizard-card" style={{ padding: '24px' }}>
            <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', marginBottom:16 }}>
              <div style={{ fontSize:16, fontWeight:600, color:'var(--ink)' }}>Criteria & Weights</div>
              <div style={{ fontSize:14, fontWeight:700, color: isValidWeight ? 'var(--green)' : 'var(--red)', fontFamily:'var(--font-mono)' }}>
                Total: {totalWeight}% {isValidWeight && '✓'}
              </div>
            </div>
            
            <div style={{ display:'flex', flexDirection:'column', gap:12 }}>
              {criteria.map((c, i) => (
                <div key={c.id} className="wizard-criterion-row" style={{ display:'flex', alignItems:'center', gap:12, background:'var(--panel-2)', padding:'12px 16px', borderRadius:'var(--radius-md)' }}>
                  <div style={{ display:'flex', flexDirection:'column' }}>
                    <button aria-label={`Move ${c.name || 'criterion'} up`} disabled={i === 0} onClick={() => setCriteria(items => moveItem(items, i, -1))}><ArrowUp size={14}/></button>
                    <button aria-label={`Move ${c.name || 'criterion'} down`} disabled={i === criteria.length - 1} onClick={() => setCriteria(items => moveItem(items, i, 1))}><ArrowDown size={14}/></button>
                  </div>
                  <div style={{ flex:1 }}>
                    <Input value={c.name} placeholder="Criterion Name" onChange={e=>updateCriterion(c.id, 'name', e.target.value)} />
                  </div>
                  <div className="wizard-weight-input" style={{ width:100 }}>
                    <Input type="number" min={0} max={100} value={c.weight} onChange={e=>updateCriterion(c.id, 'weight', e.target.value)} />
                  </div>
                  <span style={{ fontSize:16, color:'var(--muted)', fontFamily:'var(--font-mono)' }}>%</span>
                  <button onClick={()=>removeCriterion(c.id)} style={{ background:'none', border:'none', color:'var(--muted)', cursor:'pointer', padding:4 }}><Trash2 size={16}/></button>
                </div>
              ))}
            </div>

            <Btn variant="ghost" onClick={addCriterion} style={{ marginTop:12 }}><Plus size={16}/> Add Criterion</Btn>
            
            <div style={{ display:'flex', gap:12, marginTop:24 }}>
              <Btn variant="ghost" onClick={()=>navigateStep(1)}>Back</Btn>
              <Btn full variant={isValidWeight ? 'primary' : 'default'} onClick={handleNext} disabled={!isValidWeight}>Next: Build Rounds <ChevronRight size={18} /></Btn>
            </div>
          </Card>
        </Motion>
      )}

      {step === 3 && (
        <Motion type="fadeUp">
          <Card className="wizard-card" style={{ padding: '24px' }}>
            <div style={{ fontSize:16, fontWeight:600, color:'var(--ink)', marginBottom:12 }}>Rounds</div>
            <p style={{ fontSize:14, color:'var(--muted)', marginBottom:12 }}>Each round can optionally use a subset of criteria.</p>

            <div style={{ display:'flex', flexDirection:'column', gap:12 }}>
              {rounds.map((r, i) => {
                const activeCriteria = r.criteriaIds.length === 0 ? criteria.map(c=>c.id) : r.criteriaIds;
                return (
                  <div key={r.id} className="wizard-round-row" style={{ border:'1px solid var(--line)', borderRadius:'var(--radius-md)', overflow:'hidden' }}>
                    <div className="wizard-round-header" style={{ display:'flex', alignItems:'center', gap:12, background:'var(--panel-2)', padding:'12px 16px' }}>
                      <div style={{ display:'flex', flexDirection:'column' }}>
                        <button aria-label={`Move ${r.name} up`} disabled={i === 0} onClick={() => setRounds(items => moveItem(items, i, -1))}><ArrowUp size={14}/></button>
                        <button aria-label={`Move ${r.name} down`} disabled={i === rounds.length - 1} onClick={() => setRounds(items => moveItem(items, i, 1))}><ArrowDown size={14}/></button>
                      </div>
                      <div style={{ flex:1 }}>
                        <Input value={r.name} placeholder="Round Name" onChange={e=>updateRound(r.id, 'name', e.target.value)} />
                      </div>
                      <button onClick={()=>removeRound(r.id)} style={{ background:'none', border:'none', color:'var(--muted)', cursor:'pointer', padding:4 }}><Trash2 size={16}/></button>
                    </div>
                    <div style={{ padding:'20px', background:'var(--bg)' }}>
                      <div style={{ fontSize:13, fontWeight:600, color:'var(--muted)', textTransform:'uppercase', letterSpacing:'.04em', marginBottom:12 }}>Criteria included in this round:</div>
                      <div style={{ display:'flex', flexWrap:'wrap', gap:8 }}>
                        {criteria.map(c => {
                          const isActive = activeCriteria.includes(c.id);
                          return (
                            <label key={c.id} style={{ 
                              display:'inline-flex', alignItems:'center', gap:8, padding:'8px 16px', borderRadius:'var(--radius-full)', cursor:'pointer', border:'1px solid var(--line)',
                              background: isActive ? 'var(--ink)' : 'var(--panel-2)',
                              borderColor: isActive ? 'transparent' : 'var(--line)',
                              color: isActive ? 'var(--bg)' : 'var(--muted)',
                              boxShadow: isActive ? 'var(--shadow-sm)' : 'none',
                              transition:'all .15s ease', fontSize:13, fontWeight:600
                            }}>
                              <input type="checkbox" checked={isActive} onChange={()=>toggleRoundCriterion(r.id, c.id)} style={{ display:'none' }} />
                              {c.name}
                            </label>
                          )
                        })}
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>

            <Btn variant="ghost" onClick={addRound} style={{ marginTop:12 }}><Plus size={16}/> Add Round</Btn>
            
            <div style={{ display:'flex', gap:12, marginTop:24 }}>
              <Btn variant="ghost" onClick={()=>navigateStep(2)}>Back</Btn>
              <Btn full variant="success" onClick={handleSave} disabled={loading}>
                {loading ? 'Saving...' : 'Save & Continue to Dashboard'}
              </Btn>
            </div>
          </Card>
        </Motion>
      )}
    </div>
  );
}
