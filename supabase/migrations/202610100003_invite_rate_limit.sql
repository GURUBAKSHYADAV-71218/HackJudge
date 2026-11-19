-- Persistent per-IP invite resolver rate limit. Raw IPs are never stored;
-- Edge Function code supplies an HMAC-SHA256 digest using a server-only secret.
create table if not exists public.invite_rate_limits (
  client_ip_hash text not null check (client_ip_hash ~ '^[a-f0-9]{64}$'),
  minute_bucket bigint not null,
  request_count integer not null check (request_count > 0),
  primary key (client_ip_hash, minute_bucket)
);
create index if not exists idx_invite_rate_limits_bucket
  on public.invite_rate_limits(minute_bucket);

alter table public.invite_rate_limits enable row level security;
revoke all on public.invite_rate_limits from public, anon, authenticated, service_role;

create or replace function public.allow_invite_resolution(target_client_ip_hash text)
returns boolean language plpgsql security definer
set search_path = pg_catalog, public, auth, pg_temp as $$
declare
  current_bucket bigint := floor(extract(epoch from clock_timestamp()) / 60)::bigint;
  current_count integer;
begin
  if current_setting('request.jwt.claim.role', true) is distinct from 'service_role' then
    raise exception 'Service role required';
  end if;
  if target_client_ip_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'Invalid rate-limit key';
  end if;

  insert into public.invite_rate_limits(client_ip_hash, minute_bucket, request_count)
  values (target_client_ip_hash, current_bucket, 1)
  on conflict (client_ip_hash, minute_bucket)
  do update set request_count = public.invite_rate_limits.request_count + 1
  returning request_count into current_count;

  if current_count % 64 = 0 then
    delete from public.invite_rate_limits limits
    where limits.client_ip_hash = target_client_ip_hash
      and limits.minute_bucket < current_bucket - 1440;
  elsif random() < 0.01 then
    delete from public.invite_rate_limits limits
    where limits.minute_bucket < current_bucket - 1440;
  end if;

  return current_count <= 60;
end;
$$;
revoke all on function public.allow_invite_resolution(text) from public, anon, authenticated;
grant execute on function public.allow_invite_resolution(text) to service_role;
