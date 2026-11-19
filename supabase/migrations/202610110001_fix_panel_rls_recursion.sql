-- Break the panels <-> panel_judges RLS cycle. The lookup helpers are
-- SECURITY DEFINER so their internal reads do not recursively re-enter RLS.
create or replace function public.is_organizer_of_panel(check_panel_id uuid)
returns boolean
language sql
security definer
stable
set search_path = pg_catalog, public, auth, pg_temp
as $$
  select exists (
    select 1
    from public.panels p
    where p.id = check_panel_id
      and public.is_organizer_of_event(p.event_id)
  );
$$;

create or replace function public.is_active_judge_assigned_to_panel(check_panel_id uuid)
returns boolean
language sql
security definer
stable
set search_path = pg_catalog, public, auth, pg_temp
as $$
  select exists (
    select 1
    from public.panel_judges pj
    where pj.panel_id = check_panel_id
      and public.is_active_current_judge(pj.judge_id)
  );
$$;

revoke all on function public.is_organizer_of_panel(uuid) from public, anon;
grant execute on function public.is_organizer_of_panel(uuid) to authenticated, service_role;
revoke all on function public.is_active_judge_assigned_to_panel(uuid) from public, anon;
grant execute on function public.is_active_judge_assigned_to_panel(uuid) to authenticated, service_role;

drop policy if exists "assigned judge reads assigned panels" on public.panels;
create policy "assigned judge reads assigned panels" on public.panels
  for select using (public.is_active_judge_assigned_to_panel(id));

drop policy if exists "organizer full access to own panel_judges" on public.panel_judges;
create policy "organizer full access to own panel_judges" on public.panel_judges
  for all
  using (public.is_organizer_of_panel(panel_id))
  with check (public.is_organizer_of_panel(panel_id));
