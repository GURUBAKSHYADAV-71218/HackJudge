-- Local-only smoke checks. Everything is rolled back; never run against a
-- linked/hosted project. IDs are fixed so failures are easy to reproduce.
begin;

create function pg_temp.assert_true(passed boolean, description text)
returns void language plpgsql as $$
begin
  if passed is distinct from true then
    raise exception 'FAIL: %', description;
  end if;
  raise notice 'PASS: %', description;
end;
$$;

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('00000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'organizer.e2e@example.test', '', now(), '{"provider":"email","providers":["email"]}', '{"name":"E2E Organizer"}', false, false),
  ('00000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'judge.e2e@example.test', '', now(), '{"provider":"email","providers":["email"]}', '{"name":"E2E Judge"}', false, false),
  ('00000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'other-organizer.e2e@example.test', '', now(), '{"provider":"email","providers":["email"]}', '{"name":"Other Organizer"}', false, false)
on conflict (id) do nothing;

insert into public.organizers (id, name)
values
  ('00000000-0000-4000-8000-000000000001', 'E2E Organizer'),
  ('00000000-0000-4000-8000-000000000002', 'E2E Judge'),
  ('00000000-0000-4000-8000-000000000003', 'Other Organizer')
on conflict (id) do nothing;

insert into public.events (id, organizer_id, name)
values
  ('00000000-0000-4000-8000-000000000010', '00000000-0000-4000-8000-000000000001', 'Local E2E Event One'),
  ('00000000-0000-4000-8000-000000000020', '00000000-0000-4000-8000-000000000003', 'Local E2E Event Two');

insert into public.rounds (id, event_id, name, order_index)
values ('00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000010', 'Round 1', 0);

insert into public.criteria (id, event_id, name, weight, max_score, round_ids, order_index)
values ('00000000-0000-4000-8000-000000000012', '00000000-0000-4000-8000-000000000010', 'Overall', 100, 10, array['00000000-0000-4000-8000-000000000011'::uuid], 0);

insert into public.tracks (id, event_id, name)
values
  ('00000000-0000-4000-8000-000000000013', '00000000-0000-4000-8000-000000000010', 'Hardware'),
  ('00000000-0000-4000-8000-000000000023', '00000000-0000-4000-8000-000000000020', 'Hardware');

do $$
begin
  begin
    insert into public.tracks (event_id, name)
    values ('00000000-0000-4000-8000-000000000010', ' hardware ');
  exception when unique_violation then
    return;
  end;
  raise exception 'Duplicate track name was not rejected within one event';
end;
$$;

insert into public.teams (id, event_id, name, track_id)
values ('00000000-0000-4000-8000-000000000014', '00000000-0000-4000-8000-000000000010', 'Team One', '00000000-0000-4000-8000-000000000013');

insert into public.panels (id, event_id, name, track_id)
values ('00000000-0000-4000-8000-000000000015', '00000000-0000-4000-8000-000000000010', 'Hardware Panel', '00000000-0000-4000-8000-000000000013');

insert into public.judges (id, event_id, name, email, status, user_id)
values ('00000000-0000-4000-8000-000000000016', '00000000-0000-4000-8000-000000000010', 'E2E Judge', 'judge.e2e@example.test', 'active', '00000000-0000-4000-8000-000000000002');

do $$
begin
  begin
    insert into public.judges (event_id, name, email)
    values ('00000000-0000-4000-8000-000000000010', 'Duplicate Judge', 'JUDGE.E2E@EXAMPLE.TEST');
  exception when unique_violation then
    return;
  end;
  raise exception 'Duplicate judge email was not rejected within one event';
end;
$$;

insert into public.panel_judges (panel_id, judge_id)
values ('00000000-0000-4000-8000-000000000015', '00000000-0000-4000-8000-000000000016');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated","email":"organizer.e2e@example.test","email_verified":true}', true);
select public.start_event_round('00000000-0000-4000-8000-000000000010', '00000000-0000-4000-8000-000000000011');
select pg_temp.assert_true((select count(*) = 1 from public.events where id = '00000000-0000-4000-8000-000000000010'), 'organizer sees own event');
select pg_temp.assert_true((select count(*) = 1 from public.panel_judges pj join public.panels p on p.id = pj.panel_id where p.event_id = '00000000-0000-4000-8000-000000000010'), 'organizer panel join avoids RLS recursion');
select pg_temp.assert_true((select count(*) = 0 from public.events where id = '00000000-0000-4000-8000-000000000020'), 'organizer cannot see another event');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000002', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated","email":"judge.e2e@example.test","email_verified":true}', true);
select pg_temp.assert_true((select count(*) = 1 from public.panels where id = '00000000-0000-4000-8000-000000000015'), 'assigned judge sees assigned panel');
select pg_temp.assert_true((select count(*) = 1 from public.teams where id = '00000000-0000-4000-8000-000000000014'), 'assigned judge sees assigned team');
select pg_temp.assert_true((select count(*) = 0 from public.events where id = '00000000-0000-4000-8000-000000000020'), 'judge cannot see another event');
insert into public.scores (client_id, team_id, round_id, judge_id, criterion_id, value)
values ('00000000-0000-4000-8000-000000000017', '00000000-0000-4000-8000-000000000014', '00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000016', '00000000-0000-4000-8000-000000000012', 8);
select pg_temp.assert_true((select count(*) = 1 from public.scores where client_id = '00000000-0000-4000-8000-000000000017'), 'judge can submit score for assigned live work');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated","email":"organizer.e2e@example.test","email_verified":true}', true);
insert into public.overrides (event_id, round_id, team_ids, amount, resolved_by, resolution_note)
values ('00000000-0000-4000-8000-000000000010', '00000000-0000-4000-8000-000000000011', array['00000000-0000-4000-8000-000000000014'::uuid], 1.5, '00000000-0000-4000-8000-000000000001', 'Local E2E audited adjustment');
select pg_temp.assert_true((select score = 81.5 from public.team_round_results where round_id = '00000000-0000-4000-8000-000000000011' and team_id = '00000000-0000-4000-8000-000000000014'), 'score and adjustment are reflected in aggregate');

rollback;
