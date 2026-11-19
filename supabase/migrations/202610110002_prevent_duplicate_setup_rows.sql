-- Prevent duplicate tracks and judge assignments even when requests race or
-- a browser retries after the database committed but the response was lost.
-- Existing rows are preserved; this blocks only conflicting future writes.
create or replace function public.prevent_duplicate_track_name()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('track:' || new.event_id::text, 0));
  if exists (
    select 1 from public.tracks t
    where t.event_id = new.event_id
      and lower(btrim(t.name)) = lower(btrim(new.name))
      and t.id is distinct from new.id
  ) then
    raise exception 'A track with this name already exists for this event'
      using errcode = '23505', constraint = 'tracks_event_name_ci_key';
  end if;
  return new;
end;
$$;

create or replace function public.prevent_duplicate_judge_email()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, auth, pg_temp
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('judge:' || new.event_id::text, 0));
  if exists (
    select 1 from public.judges j
    where j.event_id = new.event_id
      and lower(btrim(j.email)) = lower(btrim(new.email))
      and j.id is distinct from new.id
  ) then
    raise exception 'A judge with this email is already assigned to this event'
      using errcode = '23505', constraint = 'judges_event_email_ci_key';
  end if;
  return new;
end;
$$;

revoke all on function public.prevent_duplicate_track_name() from public, anon, authenticated;
revoke all on function public.prevent_duplicate_judge_email() from public, anon, authenticated;

drop trigger if exists tracks_unique_event_name on public.tracks;
create trigger tracks_unique_event_name
  before insert or update of event_id, name on public.tracks
  for each row execute function public.prevent_duplicate_track_name();

drop trigger if exists judges_unique_event_email on public.judges;
create trigger judges_unique_event_email
  before insert or update of event_id, email on public.judges
  for each row execute function public.prevent_duplicate_judge_email();
