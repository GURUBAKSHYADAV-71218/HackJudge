import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { fetchAllRows } from '../lib/fetchAllRows';
import { useAuth } from './useAuth';

export function useJudgeData() {
  const { user } = useAuth();

  return useQuery({
    queryKey: ['judgeData', user?.id],
    enabled: !!user,
    queryFn: async () => {
      // Judges use normal, verified Supabase Auth accounts.
      const client = supabase;
      let judge = null;

      // Try by user_id first (claimed account).
      const { data: byUserId, error: userLookupError } = await client.from('judges').select('*').eq('user_id', user.id);
      if (userLookupError) throw userLookupError;
      if (byUserId?.length) {
        judge = byUserId[0];
      } else if (user.email) {
        // RLS only exposes an unclaimed row after the auth email is verified.
        const { data: byEmail, error: emailLookupError } = await client
          .from('judges').select('*').eq('email', user.email.toLowerCase()).limit(1);
        if (emailLookupError) throw emailLookupError;
        if (byEmail?.length) {
          const invitation = byEmail[0];
          const { error: claimError } = await client.rpc('claim_judge_row', { target_judge_id: invitation.id });
          if (claimError) throw claimError;
          judge = { ...invitation, user_id: user.id, status: 'active' };
        }
      }
      if (!judge) throw new Error("Judge profile not found");

      // 2. Fetch the event
      const { data: event, error: eventError } = await client
        .from('events')
        .select('*')
        .eq('id', judge.event_id)
        .single();
      if (eventError) throw eventError;

      // Unclaimed invitations are claimed above using the verified OAuth email.
      if (judge.user_id === null) {
        return { event, judge, criteria: [], rounds: [], tracks: [], teams: [], scores: [] };
      }

      // 3. Fetch related data
      const results = await Promise.all([
        client.from('criteria').select('*').eq('event_id', event.id).is('archived_at', null),
        client.from('rounds').select('*').eq('event_id', event.id),
        client.from('tracks').select('*').eq('event_id', event.id),
        client.from('teams').select('*').eq('event_id', event.id),
        fetchAllRows((from, to) => client.from('current_scores').select('*')
          .eq('judge_id', judge.id).order('revision').range(from, to)),
        client.from('panel_judges').select('panel_id, panels!inner(track_id)').eq('judge_id', judge.id),
      ]);
      const failedResult = results.find(result => result.error);
      if (failedResult?.error) throw failedResult.error;
      const [criteria, rounds, tracks, teams, scores, panelJudges] = results.map(result => result.data);

      // Filter teams based on panel assignments (matching the RLS policy)
      const allowedTrackIds = (panelJudges || []).map(pj => pj.panels.track_id).filter(Boolean);
      const filteredTeams = (teams || []).filter(t => {
        if (!t.track_id) return true;
        return allowedTrackIds.includes(t.track_id);
      }).map(team => ({
        ...team,
        // The schema stores the optional project title inside members JSON.
        projectTitle: team.members?.[0]?.title ?? null,
      }));

      return {
        event,
        judge,
        criteria: criteria || [],
        rounds: rounds || [],
        tracks: tracks || [],
        teams: filteredTeams,
        scores: scores || [],
      };
    },
  });
}

export function useJudgeMutate() {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const client = supabase;

  const submitScore = useMutation({
    mutationFn: async (scoresPayload) => {
      // scoresPayload is an array of score inserts
      const { data, error } = await client.from('scores').insert(scoresPayload);
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['judgeData', user?.id] });
    },
  });

  const claimAccount = useMutation({
    mutationFn: async (judgeId) => {
      const { data, error } = await client.rpc('claim_judge_row', { target_judge_id: judgeId });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['judgeData', user?.id] });
    },
  });

  return { submitScore, claimAccount };
}
