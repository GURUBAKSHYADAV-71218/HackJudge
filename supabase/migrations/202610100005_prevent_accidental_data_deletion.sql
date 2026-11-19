-- Protect retained event records from direct table DELETE calls. This is an
-- additive policy change; it does not delete or rewrite application rows.
do $$
declare
  item record;
begin
  for item in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('criteria', 'teams', 'tracks', 'panels', 'judges')
      and cmd in ('ALL', 'DELETE')
  loop
    execute format('drop policy %I on %I.%I', item.policyname, item.schemaname, item.tablename);
  end loop;
end;
$$;

drop policy if exists "organizer deletes own events" on public.events;
drop policy if exists "organizer reads own criteria" on public.criteria;
drop policy if exists "organizer inserts own criteria" on public.criteria;
drop policy if exists "organizer updates own criteria" on public.criteria;
drop policy if exists "organizer reads own teams" on public.teams;
drop policy if exists "organizer inserts own teams" on public.teams;
drop policy if exists "organizer updates own teams" on public.teams;
drop policy if exists "organizer reads own tracks" on public.tracks;
drop policy if exists "organizer inserts own tracks" on public.tracks;
drop policy if exists "organizer updates own tracks" on public.tracks;
drop policy if exists "organizer reads own panels" on public.panels;
drop policy if exists "organizer inserts own panels" on public.panels;
drop policy if exists "organizer updates own panels" on public.panels;
drop policy if exists "organizer reads own judges" on public.judges;
drop policy if exists "organizer inserts own judges" on public.judges;
drop policy if exists "organizer updates own judges" on public.judges;

create policy "organizer reads own criteria" on public.criteria
  for select using (public.is_organizer_of_event(event_id));
create policy "organizer inserts own criteria" on public.criteria
  for insert with check (public.is_organizer_of_event(event_id));
create policy "organizer updates own criteria" on public.criteria
  for update using (public.is_organizer_of_event(event_id))
  with check (public.is_organizer_of_event(event_id));

create policy "organizer reads own teams" on public.teams
  for select using (public.is_organizer_of_event(event_id));
create policy "organizer inserts own teams" on public.teams
  for insert with check (public.is_organizer_of_event(event_id));
create policy "organizer updates own teams" on public.teams
  for update using (public.is_organizer_of_event(event_id))
  with check (public.is_organizer_of_event(event_id));

create policy "organizer reads own tracks" on public.tracks
  for select using (public.is_organizer_of_event(event_id));
create policy "organizer inserts own tracks" on public.tracks
  for insert with check (public.is_organizer_of_event(event_id));
create policy "organizer updates own tracks" on public.tracks
  for update using (public.is_organizer_of_event(event_id))
  with check (public.is_organizer_of_event(event_id));

create policy "organizer reads own panels" on public.panels
  for select using (public.is_organizer_of_event(event_id));
create policy "organizer inserts own panels" on public.panels
  for insert with check (public.is_organizer_of_event(event_id));
create policy "organizer updates own panels" on public.panels
  for update using (public.is_organizer_of_event(event_id))
  with check (public.is_organizer_of_event(event_id));

create policy "organizer reads own judges" on public.judges
  for select using (public.is_organizer_of_event(event_id));
create policy "organizer inserts own judges" on public.judges
  for insert with check (public.is_organizer_of_event(event_id));
create policy "organizer updates own judges" on public.judges
  for update using (public.is_organizer_of_event(event_id))
  with check (public.is_organizer_of_event(event_id));

revoke delete on table public.events, public.criteria, public.teams, public.tracks, public.panels, public.judges
  from public, anon, authenticated;
revoke delete on table public.rounds from public, anon, authenticated;
revoke all on function public.delete_event(uuid) from public, anon, authenticated;
