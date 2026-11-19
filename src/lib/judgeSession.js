import { parseJwt } from '../security';

const STORAGE_KEY = 'hackjudge_judge_access_token';
const CHANGE_EVENT = 'hackjudge:judge-session-change';
const RENEW_BEFORE_SECONDS = 24 * 60 * 60;
let renewalPromise = null;

export function getStoredJudgeToken() {
  try {
    return localStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
}

export function setJudgeToken(token) {
  try {
    localStorage.setItem(STORAGE_KEY, token);
    window.dispatchEvent(new Event(CHANGE_EVENT));
  } catch {
    throw new Error('Could not store the judge session in this browser.');
  }
}

export function clearJudgeToken() {
  try {
    localStorage.removeItem(STORAGE_KEY);
    window.dispatchEvent(new Event(CHANGE_EVENT));
  } catch {
    // Nothing else can be done if browser storage is unavailable.
  }
}

export function hasJudgeToken() {
  return !!getStoredJudgeToken();
}

export function subscribeToJudgeToken(callback) {
  window.addEventListener(CHANGE_EVENT, callback);
  return () => window.removeEventListener(CHANGE_EVENT, callback);
}

export async function getValidJudgeToken(supabase) {
  const token = getStoredJudgeToken();
  if (!token) return null;

  const payload = parseJwt(token);
  if (!payload?.judge_id || !Number.isFinite(payload.exp)) {
    clearJudgeToken();
    return null;
  }

  if (payload.exp - Math.floor(Date.now() / 1000) > RENEW_BEFORE_SECONDS) return token;

  if (!renewalPromise) {
    renewalPromise = (async () => {
      try {
        const { data, error } = await supabase.functions.invoke('resolve-judge-token', {
          body: { refresh_jwt: token },
        });
        if (error) {
          const status = error.context?.status ?? error.status;
          if (status === 401 || status === 404) clearJudgeToken();
          return null;
        }
        if (!data?.jwt) return null;
        setJudgeToken(data.jwt);
        return data.jwt;
      } catch {
        // Preserve the still-stored token during transient network failures.
        return null;
      }
    })().finally(() => {
      renewalPromise = null;
    });
  }

  return renewalPromise;
}
