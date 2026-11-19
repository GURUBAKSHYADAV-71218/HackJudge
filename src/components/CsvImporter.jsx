import { useState, useRef } from 'react';
import { Upload, ChevronRight, Check, X, AlertTriangle } from 'lucide-react';
import { Btn, Select, Input, Alert } from './ui';
import { uid } from '../security';

function parseCsv(text) {
  const source = text.replace(/^\uFEFF/, '');
  const records = [];
  let record = [];
  let field = '';
  let quoted = false;

  for (let i = 0; i < source.length; i++) {
    const char = source[i];
    if (quoted) {
      if (char === '"' && source[i + 1] === '"') {
        field += '"';
        i++;
      } else if (char === '"') {
        quoted = false;
      } else {
        field += char;
      }
    } else if (char === '"' && field.length === 0) {
      quoted = true;
    } else if (char === ',') {
      record.push(field.trim());
      field = '';
    } else if (char === '\n' || char === '\r') {
      if (char === '\r' && source[i + 1] === '\n') i++;
      record.push(field.trim());
      if (record.some(value => value.length > 0)) records.push(record);
      record = [];
      field = '';
    } else {
      field += char;
    }
  }

  if (quoted) return { headers: [], rows: [], error: 'CSV has an unclosed quoted field.' };
  record.push(field.trim());
  if (record.some(value => value.length > 0)) records.push(record);
  if (!records.length) return { headers: [], rows: [] };

  const headers = records[0];
  const rows = records.slice(1).map(row => Array.from({ length: headers.length }, (_, i) => row[i] || ''));
  return { headers, rows };
}

function validateTeamRows(rows, existingNames, tracks) {
  const normalizedExisting = new Set(existingNames.map(name => name.trim().toLocaleLowerCase()));
  const tracksByName = new Map(tracks.map(track => [track.name.trim().toLocaleLowerCase(), track]));
  const activeNameCounts = rows.reduce((counts, row) => {
    if (!row.skip && row.name.trim()) {
      const name = row.name.trim().toLocaleLowerCase();
      counts.set(name, (counts.get(name) || 0) + 1);
    }
    return counts;
  }, new Map());

  return rows.map(row => {
    if (row.skip) return { ...row, errors: [] };
    const normalizedName = row.name.trim().toLocaleLowerCase();
    const errors = [];
    if (!row.name.trim()) errors.push('Missing team name');
    if (row.name.trim().length > 60) errors.push('Team name exceeds 60 characters');
    if (row.projectTitle.trim().length > 120) errors.push('Project title exceeds 120 characters');
    if (normalizedExisting.has(normalizedName) || activeNameCounts.get(normalizedName) > 1) errors.push('Duplicate team name');
    if (row.trackName.trim() && !tracksByName.has(row.trackName.trim().toLocaleLowerCase())) {
      errors.push(`Unknown track: ${row.trackName.trim()}`);
    }
    return { ...row, errors };
  });
}

export function CsvImporter({ onImport, onCancel, existingTeamNames = [], tracks = [], maxRows = 1000 }) {
  const [step, setStep] = useState(1); // 1: Upload, 2: Map, 3: Validate
  const [data, setData] = useState(null); // { headers, rows }
  const [mapping, setMapping] = useState({ name: -1, projectTitle: -1, track: -1 });
  const [validatedData, setValidatedData] = useState([]);
  const fileInputRef = useRef(null);

  const handleFileUpload = (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    if (file.size > 2 * 1024 * 1024) return alert('CSV files must be 2 MB or smaller.');
    const reader = new FileReader();
    reader.onload = (evt) => {
      const csv = parseCsv(evt.target.result);
      if (csv.error) return alert(csv.error);
      if (csv.rows.length === 0) return alert('CSV is empty or invalid.');
      if (csv.rows.length > maxRows) return alert(`This event has room for ${maxRows} more teams.`);
      
      // Auto-detect columns
      const m = { name: -1, projectTitle: -1, track: -1 };
      csv.headers.forEach((h, i) => {
        const hl = h.trim().toLowerCase();
        if (hl.includes('track')) m.track = i;
        else if (hl.includes('team') || hl === 'name') m.name = i;
        else if (hl.includes('title') || hl.includes('project')) m.projectTitle = i;
      });
      
      setMapping(m);
      setData(csv);
      setStep(2);
    };
    reader.onerror = () => alert('Could not read this CSV file.');
    reader.readAsText(file);
  };

  const handleMapNext = () => {
    if (mapping.name === -1) return alert('You must map a column to Team Name.');
    
    // Build validation list
    const v = data.rows.map(r => {
      const name = r[mapping.name] || '';
      const title = mapping.projectTitle !== -1 ? r[mapping.projectTitle] : '';
      const trackName = mapping.track !== -1 ? (r[mapping.track] || '').trim() : '';
      const track = tracks.find(item => item.name.trim().toLocaleLowerCase() === trackName.toLocaleLowerCase());
      return {
        id: uid(), name: name.trim(), projectTitle: title.trim(),
        trackName, trackId: track?.id || '', errors: [], skip: false,
      };
    });
    setValidatedData(validateTeamRows(v, existingTeamNames, tracks));
    setStep(3);
  };

  const handleImport = () => {
    const final = validatedData.filter(x => !x.skip && x.errors.length === 0).map(x => ({
          name: x.name, projectTitle: x.projectTitle, trackId: x.trackId || null
    }));
    onImport(final);
  };

  if (step === 1) {
    return (
      <div style={{ padding: 24, border: '2px dashed var(--line)', borderRadius: 12, textAlign: 'center' }}>
        <input type="file" accept=".csv" ref={fileInputRef} onChange={handleFileUpload} style={{ display: 'none' }} />
        <div style={{ width: 48, height: 48, borderRadius: '50%', background: 'var(--panel-2)', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', marginBottom: 16 }}>
          <Upload size={24} color="var(--muted)" />
        </div>
        <h3 style={{ fontSize: 18, fontWeight: 600, color: 'var(--ink)', marginBottom: 8, fontFamily: 'var(--font-display)' }}>Upload Teams CSV</h3>
        <p style={{ fontSize: 14, color: 'var(--muted)', marginBottom: 24 }}>Upload an export from Devfolio, Unstop, or Excel.</p>
        <div style={{ display: 'flex', gap: 12, justifyContent: 'center' }}>
          <Btn variant="ghost" onClick={onCancel}>Cancel</Btn>
          <Btn onClick={() => fileInputRef.current.click()}>Select File</Btn>
        </div>
      </div>
    );
  }

  if (step === 2) {
    return (
      <div style={{ padding: 24, border: '1px solid var(--line)', borderRadius: 12, background: 'var(--panel)' }}>
        <h3 style={{ fontSize: 18, fontWeight: 600, color: 'var(--ink)', marginBottom: 16, fontFamily: 'var(--font-display)' }}>Map Columns</h3>
        <p style={{ fontSize: 14, color: 'var(--muted)', marginBottom: 24 }}>
          We attempted to detect your columns. Map Track to the column containing configured event track names (for example, Hardware or Software). Leave it unmapped for General teams.
        </p>
        
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16, marginBottom: 32 }}>
          <div className="csv-column-map-row" style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
            <span style={{ width: 120, fontSize: 14, fontWeight: 600, color: 'var(--ink)' }}>Team Name *</span>
            <Select value={mapping.name} onChange={e => setMapping(m => ({ ...m, name: Number(e.target.value) }))} style={{ flex: 1 }}>
              <option value={-1}>— Ignore —</option>
              {data.headers.map((h, i) => <option key={i} value={i}>{h || `Column ${i+1}`}</option>)}
            </Select>
          </div>
          <div className="csv-column-map-row" style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
            <span style={{ width: 120, fontSize: 14, fontWeight: 600, color: 'var(--ink)' }}>Project Title</span>
            <Select value={mapping.projectTitle} onChange={e => setMapping(m => ({ ...m, projectTitle: Number(e.target.value) }))} style={{ flex: 1 }}>
              <option value={-1}>— Ignore —</option>
              {data.headers.map((h, i) => <option key={i} value={i}>{h || `Column ${i+1}`}</option>)}
            </Select>
          </div>
          <div className="csv-column-map-row" style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
            <span style={{ width: 120, fontSize: 14, fontWeight: 600, color: 'var(--ink)' }}>Track</span>
            <Select value={mapping.track} onChange={e => setMapping(m => ({ ...m, track: Number(e.target.value) }))} style={{ flex: 1 }}>
              <option value={-1}>— General / Ignore —</option>
              {data.headers.map((h, i) => <option key={i} value={i}>{h || `Column ${i+1}`}</option>)}
            </Select>
          </div>
        </div>
        
        <div style={{ display: 'flex', gap: 12, justifyContent: 'flex-end' }}>
          <Btn variant="ghost" onClick={() => setStep(1)}>Back</Btn>
          <Btn onClick={handleMapNext}>Validate Data <ChevronRight size={16}/></Btn>
        </div>
      </div>
    );
  }

  if (step === 3) {
    const ready = validatedData.filter(x => !x.skip && x.errors.length === 0).length;
    const errors = validatedData.filter(x => !x.skip && x.errors.length > 0).length;
    
    return (
      <div style={{ padding: 24, border: '1px solid var(--line)', borderRadius: 12, background: 'var(--panel)' }}>
        <h3 style={{ fontSize: 18, fontWeight: 600, color: 'var(--ink)', marginBottom: 8, fontFamily: 'var(--font-display)' }}>Validation</h3>
        
        {errors > 0 ? (
          <Alert variant="error" style={{ marginBottom: 16 }}>
            {ready} teams ready, {errors} need attention. Fix them inline or skip them.
          </Alert>
        ) : (
          <Alert variant="success" style={{ marginBottom: 16 }}>
            All {ready} teams look good and are ready to import. Track names are matched without regard to capitalization.
          </Alert>
        )}
        
        <div style={{ maxHeight: 300, overflowY: 'auto', border: '1px solid var(--line)', borderRadius: 8, marginBottom: 24 }}>
          {validatedData.map((row, i) => (
            <div key={row.id} className="csv-validation-row" style={{ display: 'flex', gap: 12, padding: 12, borderBottom: i === validatedData.length - 1 ? 'none' : '1px solid var(--line)', background: row.skip ? 'var(--panel-2)' : row.errors.length ? 'var(--red-s)' : 'var(--bg)', opacity: row.skip ? 0.5 : 1 }}>
              <div className="csv-validation-inputs" style={{ flex: 1, display: 'flex', gap: 8 }}>
                <Input value={row.name} maxLength={60} onChange={e => {
                  const n = e.target.value;
                  setValidatedData(v => validateTeamRows(v.map(x => x.id === row.id ? { ...x, name: n } : x), existingTeamNames, tracks));
                }} disabled={row.skip} placeholder="Team Name" style={{ flex: 1, padding: '4px 8px', height: 32 }} />
                <Input value={row.projectTitle} maxLength={120} onChange={e => {
                  setValidatedData(v => v.map(x => x.id === row.id ? { ...x, projectTitle: e.target.value } : x));
                }} disabled={row.skip} placeholder="Project Title" style={{ flex: 1, padding: '4px 8px', height: 32 }} />
                <Select
                  aria-label={`Track for ${row.name || 'team'}`}
                  value={row.trackId || (row.trackName ? '__unmatched__' : '')}
                  onChange={e => {
                    const track = tracks.find(item => item.id === e.target.value);
                    setValidatedData(v => validateTeamRows(v.map(x => x.id === row.id
                      ? { ...x, trackId: track?.id || '', trackName: track?.name || '' }
                      : x), existingTeamNames, tracks));
                  }}
                  disabled={row.skip}
                  style={{ flex: 1, minWidth: 0, padding: '4px 28px 4px 8px', height: 32, fontSize: 12 }}
                >
                  <option value="">General / No track</option>
                  {row.trackName && !row.trackId && <option value="__unmatched__">Unknown: {row.trackName}</option>}
                  {tracks.map(track => <option key={track.id} value={track.id}>{track.name}</option>)}
                </Select>
              </div>
              <div className="csv-validation-errors" style={{ width: 140, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
                {!row.skip && row.errors.map(err => <span key={err} style={{ fontSize: 11, color: 'var(--red)', fontWeight: 600 }}>{err}</span>)}
              </div>
              <Btn size="xs" variant="ghost" onClick={() => setValidatedData(v => validateTeamRows(v.map(x => x.id === row.id ? { ...x, skip: !x.skip } : x), existingTeamNames, tracks))}>
                {row.skip ? 'Restore' : 'Skip'}
              </Btn>
            </div>
          ))}
        </div>
        
        <div style={{ display: 'flex', gap: 12, justifyContent: 'flex-end' }}>
          <Btn variant="ghost" onClick={() => setStep(2)}>Back</Btn>
          <Btn variant="primary" onClick={handleImport} disabled={ready === 0}>Import {ready} Teams</Btn>
        </div>
      </div>
    );
  }
  
  return null;
}
