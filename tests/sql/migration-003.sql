-- Local-only regression checks for migration 202610110003.
-- Run only against scratch/core-e2e; all fixtures are rolled back.
begin;

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous
) values
  ('10000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'organizer.m003@example.test', '', now(), '{"provider":"email","providers":["email"]}', '{"name":"M003 Organizer"}', false, false),
  ('10000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'judge.m003@example.test', '', now(), '{"provider":"email","providers":["email"]}', '{"name":"M003 Judge"}', false, false)
on conflict (id) do nothing;

insert into public.organizers (id, name)
values ('10000000-0000-4000-8000-000000000001', 'M003 Organizer')
on conflict (id) do nothing;

insert into public.events (id, organizer_id, name)
values ('10000000-0000-4000-8000-000000000010', '10000000-0000-4000-8000-000000000001', 'M003 Regression Event');
insert into public.rounds (id, event_id, name, order_index)
values
  ('10000000-0000-4000-8000-000000000011', '10000000-0000-4000-8000-000000000010', 'Round 1', 0),
  ('10000000-0000-4000-8000-000000000012', '10000000-0000-4000-8000-000000000010', 'Round 2', 1);
insert into public.criteria (id, event_id, name, weight, max_score, round_ids, order_index)
values ('10000000-0000-4000-8000-000000000013', '10000000-0000-4000-8000-000000000010', 'Overall', 100, 10, '{}', 0);
insert into public.tracks (id, event_id, name)
values ('10000000-0000-4000-8000-000000000014', '10000000-0000-4000-8000-000000000010', 'Hardware');
insert into public.teams (id, event_id, name, track_id)
values ('10000000-0000-4000-8000-000000000015', '10000000-0000-4000-8000-000000000010', 'Team One', '10000000-0000-4000-8000-000000000014');
insert into public.panels (id, event_id, name, track_id)
values ('10000000-0000-4000-8000-000000000016', '10000000-0000-4000-8000-000000000010', 'Hardware Panel', '10000000-0000-4000-8000-000000000014');
insert into public.judges (id, event_id, name, email)
values ('10000000-0000-4000-8000-000000000017', '10000000-0000-4000-8000-000000000010', 'M003 Judge', 'judge.m003@example.test');
insert into public.panel_judges (panel_id, judge_id)
values ('10000000-0000-4000-8000-000000000016', '10000000-0000-4000-8000-000000000017');

select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated","email":"organizer.m003@example.test","email_verified":true}', true);

do $$
begin
  begin
    perform public.start_event_round('10000000-0000-4000-8000-000000000010', '10000000-0000-4000-8000-000000000011');
  exception when others then
    if sqlerrm not like 'Every team must have at least one judge%' then raise; end if;
    return;
  end;
  raise exception 'FAIL: an unclaimed invited judge incorrectly satisfied round coverage';
end;
$$;

update public.judges
set user_id = '10000000-0000-4000-8000-000000000002', status = 'active'
where id = '10000000-0000-4000-8000-000000000017';
select public.start_event_round('10000000-0000-4000-8000-000000000010', '10000000-0000-4000-8000-000000000011');

do $$
begin
  begin
    update public.criteria set name = 'Changed' where id = '10000000-0000-4000-8000-000000000013';
  exception when others then
    if sqlerrm not like 'Scoring criteria are locked%' then raise; end if;
    return;
  end;
  raise exception 'FAIL: scoring criteria remained editable after round start';
end;
$$;

do $$
begin
  begin
    insert into public.teams (event_id, name) values ('10000000-0000-4000-8000-000000000010', 'Late Team');
  exception when others then
    if sqlerrm not like 'The team roster is locked%' then raise; end if;
    return;
  end;
  raise exception 'FAIL: a team could be added after round start';
end;
$$;

do $$
begin
  begin
    insert into public.judges (event_id, name, email) values ('10000000-0000-4000-8000-000000000010', 'Late Judge', 'late.m003@example.test');
  exception when others then
    if sqlerrm not like 'Judge assignments are locked%' then raise; end if;
    return;
  end;
  raise exception 'FAIL: a new judge could be assigned after round start';
end;
$$;

update public.rounds
set status = 'closed', advanced_team_ids = array['10000000-0000-4000-8000-000000000015'::uuid]
where id = '10000000-0000-4000-8000-000000000011';
select public.start_event_round('10000000-0000-4000-8000-000000000010', '10000000-0000-4000-8000-000000000012');
update public.rounds set advanced_team_ids = '{}'::uuid[] where id = '10000000-0000-4000-8000-000000000011';

select 'PASS: unclaimed judges do not satisfy round coverage' as check_result;
select 'PASS: active assigned judge permits round start' as check_result;
select 'PASS: scoring criteria and roster lock after round start' as check_result;
select 'PASS: shortlist can still change after a later round begins' as check_result;

rollback;
