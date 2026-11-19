import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { fetchAllRows } from '../lib/fetchAllRows';
import { useAuth } from './useAuth';

// Fetch all data for the active event (or fallback to latest)
export function useEventData() {
  const { user } = useAuth();

  return useQuery({
    queryKey: ['eventData', user?.id],
    enabled: !!user?.id,
    queryFn: async () => {
      const storedId = localStorage.getItem('hackjudge_active_event_id');
      let query = supabase.from('events').select('*').eq('organizer_id', user.id);
      
      if (storedId) {
        query = query.eq('id', storedId);
      } else {
        query = query.order('created_at', { ascending: false }).limit(1);
      }

      let { data: event, error: eventError } = await query.single();

      if (eventError && eventError.code !== 'PGRST116') throw eventError;
      if (!event && storedId) {
        const fallback = await supabase.from('events').select('*')
          .eq('organizer_id', user.id)
          .order('created_at', { ascending: false })
          .limit(1)
          .single();
        event = fallback.data;
        eventError = fallback.error;
        if (eventError && eventError.code !== 'PGRST116') throw eventError;
      }
      if (!event) return null;
      
      // Save the id so future reloads stick to it
      if (!storedId || storedId !== event.id) {
        localStorage.setItem('hackjudge_active_event_id', event.id);
      }

      // Fetch bounded configuration plus paginated aggregates. Raw scores are
      // append-only revisions; the canonical view avoids loading that history.
      const results = await Promise.all([
        supabase.from('criteria').select('*').eq('event_id', event.id),
        supabase.from('rounds').select('*').eq('event_id', event.id),
        supabase.from('tracks').select('*').eq('event_id', event.id),
        supabase.from('panels').select('*').eq('event_id', event.id),
        // panel_judges relies on inner join with panels to filter by event_id
        supabase.from('panel_judges').select('*, panels!inner(event_id)').eq('panels.event_id', event.id),
        supabase.from('judges').select('*').eq('event_id', event.id),
        supabase.from('teams').select('*').eq('event_id', event.id),
        fetchAllRows((from, to) => supabase.from('overrides').select('*')
          .eq('event_id', event.id).order('resolved_at').order('id').range(from, to)),
        fetchAllRows((from, to) => supabase.from('team_round_results').select('*')
          .eq('event_id', event.id).order('round_id').order('team_id').range(from, to)),
      ]);

      const failedResult = results.slice(0, 7).find(result => result.error);
      if (failedResult?.error) throw failedResult.error;
      const [criteria, rounds, tracks, panels, panel_judges, judges, teams] = results
        .slice(0, 7).map(result => result.data);
      const overrides = results[7];
      const team_round_results = results[8];
      const roundIds = (rounds || []).map(round => round.id);
      const scores = roundIds.length
        ? await fetchAllRows((from, to) => supabase.from('current_scores').select('*')
          .in('round_id', roundIds).order('revision').range(from, to))
        : [];

      return {
        ...event,
        criteria: criteria || [],
        rounds: rounds || [],
        tracks: tracks || [],
        panels: panels || [],
        panel_judges: panel_judges || [],
        judges: judges || [],
        teams: (teams || []).map(team => ({
          ...team,
          // The schema stores the optional project title inside members JSON.
          projectTitle: team.members?.[0]?.title ?? null,
        })),
        scores: scores || [],
        overrides: overrides || [],
        team_round_results: team_round_results || [],
      };
    },
  });
}

export function useOrganizerEvents() {
  const { user } = useAuth();
  return useQuery({
    queryKey: ['organizerEvents', user?.id],
    enabled: !!user?.id,
    queryFn: async () => {
      return fetchAllRows((from, to) => supabase
        .from('events')
        .select('id, name, status, created_at')
        .eq('organizer_id', user.id)
        .order('created_at', { ascending: false })
        .order('id', { ascending: true })
        .range(from, to));
    }
  });
}


// Generic mutation factory for non-destructive organizer changes.
export function useMutateEventData(table) {
  const queryClient = useQueryClient();
  const { user } = useAuth();

  const add = useMutation({
    mutationFn: async (payload) => {
      const { data, error } = await supabase.from(table).insert(payload).select().single();
      if (error) throw error;
      return data;
    },
    onSuccess: (createdRow) => {
      const queryKey = ['eventData', user?.id];
      // Reflect the committed insert immediately. A failed refresh of another
      // event table must not make a successful write look unsuccessful and
      // invite the organizer to submit the same row again.
      queryClient.setQueryData(queryKey, (current) => {
        if (!current || !createdRow?.id) return current;
        const rows = current[table] || [];
        if (rows.some((row) => row.id === createdRow.id)) return current;
        return { ...current, [table]: [...rows, createdRow] };
      });
      void queryClient.invalidateQueries({ queryKey }).catch((error) => {
        console.error(`[HackJudge] Could not refresh ${table} after insert:`, error);
      });
    },
  });

  const update = useMutation({
    mutationFn: async ({ id, payload }) => {
      const { data, error } = await supabase.from(table).update(payload).eq('id', id).select().single();
      if (error) throw error;
      return data;
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['eventData', user?.id] }),
  });

  return { add, update };
}

