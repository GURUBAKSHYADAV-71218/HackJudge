import { useState, useEffect } from 'react';
import { ThemeProvider } from './hooks/useTheme.jsx';
import { ToastContainer } from './components/ui';
import Landing from './pages/Landing';
import OrganizerDashboard from './pages/organizer/index.jsx';
import JudgeDashboard from './pages/JudgeDashboard';
import MagicLinkAuth from './pages/MagicLinkAuth';
import EventWizard from './pages/EventWizard.jsx';

import { AuthProvider, useAuth } from './hooks/useAuth.jsx';
import { supabase } from './lib/supabase';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { Analytics } from '@vercel/analytics/react';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
      staleTime: 5 * 60 * 1000,
    },
  },
});

function filterAnalyticsEvent(event) {
  try {
    const url = new URL(event.url, window.location.origin);
    // Judge invitation tokens are placed in the URL fragment. Never transmit
    // those URLs, and drop fragments so internal app navigation is not exposed.
    if (url.hash.startsWith('#/j/')) return null;
    url.hash = '';
    return { ...event, url: url.toString() };
  } catch {
    return null;
  }
}

function Router() {
  const { user, loading, signOut } = useAuth();
  // Auth emits a new `user` object when it refreshes a token (often while a
  // tab is in the background). Role resolution must follow identity changes,
  // not object identity, or the role route briefly unmounts the dashboard and
  // resets page-local state such as the judge's selected team.
  const userId = user?.id;
  const userEmail = user?.email;
  const [magicToken, setMagicToken] = useState(() => {
    const hash = window.location.hash;
    return hash.startsWith('#/j/') ? hash.replace('#/j/', '') : null;
  });
  const [dbRole, setDbRole] = useState(null); // null (loading/unknown), 'organizer', 'judge'

  useEffect(() => {
    // Listen for hash changes
    const onHashChange = () => {
      const h = window.location.hash;
      if (h.startsWith('#/j/')) setMagicToken(h.replace('#/j/', ''));
      else setMagicToken(null);
    };
    window.addEventListener('hashchange', onHashChange);
    return () => window.removeEventListener('hashchange', onHashChange);
  }, []);

  useEffect(() => {
    async function resolveRole() {
      if (!userId) {
        setDbRole(null);
        return;
      }
      // If we have a magic link token, we don't need to query db role yet
      if (magicToken) return;

      const loginIntent = sessionStorage.getItem('hackjudge_login_intent');
      if (loginIntent === 'organizer' || loginIntent === 'organizer-create') {
        sessionStorage.removeItem('hackjudge_login_intent');
        setDbRole('organizer');
        return;
      }

      // Reset while resolving to avoid stale state flash
      setDbRole(null);

      try {
        const { data: judgeRows, error } = await supabase
          .from('judges')
          .select('id')
          .eq('user_id', userId)
          .limit(1);

        if (error) {
          setDbRole('error');
          return;
        }

        let isJudge = judgeRows?.length > 0;
        if (!isJudge && userEmail) {
          const { data: unclaimedRows, error: unclaimedError } = await supabase
            .from('judges')
            .select('id')
            .eq('email', userEmail.toLowerCase())
            .limit(1);
          if (unclaimedError) {
            setDbRole('error');
            return;
          }
          isJudge = unclaimedRows?.length > 0;
        }

        if (isJudge) {
          sessionStorage.removeItem('hackjudge_login_intent');
          setDbRole('judge');
          return;
        }

        sessionStorage.removeItem('hackjudge_login_intent');
        if (loginIntent === 'judge') {
          setDbRole('no_judge_assignment');
          return;
        }

        // Default to organizer if no judge row found
        setDbRole('organizer');
      } catch {
        setDbRole('error');
      }
    }
    
    resolveRole();
  }, [userId, userEmail, magicToken]);

  if (loading) {
    return <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'var(--bg)', color: 'var(--muted)' }}>Loading...</div>;
  }
  
  if (magicToken) return <MagicLinkAuth />;
  
  if (!user) return <Landing />;

  // OAuth may consume the URL fragment for its own callback data. The wizard
  // draft is the durable same-tab signal that this user is resuming event setup.
  const hasEventWizardDraft = Boolean(sessionStorage.getItem('hackjudge_event_wizard_draft'));
  if (hasEventWizardDraft || window.location.hash.startsWith('#create')) {
    return <EventWizard existingUser={user} onCancel={() => {
      sessionStorage.removeItem('hackjudge_event_wizard_draft');
      window.location.hash = '';
    }} />;
  }

  // If we are at #/projector, render Projector (greyed out but route still exists)
  const hash = window.location.hash;
  if (hash === '#/projector') return <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'var(--bg)', color: 'var(--muted)', fontFamily: 'var(--font-display)', fontSize: 24 }}>Projector is coming soon.</div>;

  if (dbRole === 'error') return (
    <div style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column', gap: 16, alignItems: 'center', justifyContent: 'center', background: 'var(--bg)', color: 'var(--muted)' }}>
      <div>We could not verify your account role. Please try again.</div>
      <button onClick={() => setDbRole(null)}>Retry</button>
      <button onClick={signOut}>Sign out</button>
    </div>
  );

  if (dbRole === 'no_judge_assignment') return (
    <div style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column', gap: 16, alignItems: 'center', justifyContent: 'center', padding: 24, background: 'var(--bg)', color: 'var(--muted)', textAlign: 'center' }}>
      <div>This Google account is not assigned as a judge for an event. Ask the organizer to add this exact email address.</div>
      <button onClick={signOut}>Sign out</button>
    </div>
  );

  // If they have an email, wait for dbRole to resolve
  if (!dbRole) return <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'var(--bg)', color: 'var(--muted)' }}>Resolving role...</div>;

  if (dbRole === 'judge') return <JudgeDashboard />;
  
  // Default to Organizer
  return <OrganizerDashboard />;
}

import { ErrorBoundary } from './components/ErrorBoundary.jsx';

export default function App() {
  return (
    <ThemeProvider>
      <QueryClientProvider client={queryClient}>
        <AuthProvider>
          <ErrorBoundary>
            <Router />
            <ToastContainer />
            <Analytics beforeSend={filterAnalyticsEvent} />
          </ErrorBoundary>
        </AuthProvider>
      </QueryClientProvider>
    </ThemeProvider>
  );
}
