-- =====================================================================
-- DOMOS Lucky Spin — Supabase schema
-- Paste this whole file into Supabase → SQL Editor → Run.
-- Safe to run again: it only creates what is missing and replaces functions.
--
-- Security model
--   * Tables have Row Level Security ON and NO policies, so the browser
--     (anon / publishable key) can never read or write them directly.
--   * Everything goes through the SECURITY DEFINER functions below.
--   * The prize is chosen on the server inside `spin()`. The browser only
--     animates the wheel to the prize the server returns.
--   * Staff functions require the staff PIN (stored in `settings`).
-- =====================================================================

create table if not exists public.settings (
  id            int primary key default 1 check (id = 1),
  booth_number  text not null default 'Hall 2 · Booth A18',
  daily_limit   int  not null default 1 check (daily_limit between 1 and 20),
  announcement  text not null default '',
  whatsapp      text not null default '60165302629',
  admin_pin     text not null default '8888',
  updated_at    timestamptz not null default now()
);

create table if not exists public.prizes (
  id           text primary key default ('p' || substr(md5(random()::text), 1, 10)),
  name         text not null,
  wheel_title  text not null default '',
  wheel_sub    text not null default '',
  subtitle     text not null default '',
  category     text not null default 'Smart Home',
  icon         text not null default 'gift',
  color        text not null default '#0284C7',
  weight       int  not null default 10 check (weight >= 0),
  total        int  not null default 100 check (total >= 0),
  remaining    int  not null default 100 check (remaining >= 0),
  active       boolean not null default true,
  grand        boolean not null default false,
  sort_order   int  not null default 0,
  note         text not null default '',
  updated_at   timestamptz not null default now()
);

create table if not exists public.spins (
  code         text primary key,
  phone        text not null,
  name         text not null default '',
  prize_id     text not null,
  prize_name   text not null,
  grand        boolean not null default false,
  spin_date    date not null,
  created_at   timestamptz not null default now(),
  status       text not null default 'won' check (status in ('won','redeemed')),
  redeemed_at  timestamptz,
  redeemed_by  text,
  device       text not null default ''
);
create index if not exists spins_phone_date on public.spins (phone, spin_date);
create index if not exists spins_created on public.spins (created_at desc);

create table if not exists public.pin_attempts (
  id          bigserial primary key,
  created_at  timestamptz not null default now()
);

alter table public.settings     enable row level security;
alter table public.prizes       enable row level security;
alter table public.spins        enable row level security;
alter table public.pin_attempts enable row level security;
revoke all on public.settings, public.prizes, public.spins, public.pin_attempts from anon, authenticated;

insert into public.settings (id) values (1) on conflict (id) do nothing;

-- v2: the look of the page (luxe / classic / cyber), switched from the Control Room.
alter table public.settings add column if not exists theme text not null default 'luxe';
alter table public.settings drop constraint if exists settings_theme_check;
alter table public.settings add constraint settings_theme_check check (theme in ('luxe', 'classic', 'cyber'));

-- ---------------------------------------------------------------------
-- helpers (not callable from the browser)
-- ---------------------------------------------------------------------
create or replace function public._today() returns date
language sql stable set search_path = public as $$
  select (now() at time zone 'Asia/Kuala_Lumpur')::date
$$;

create or replace function public._clean_phone(p text) returns text
language plpgsql immutable set search_path = public as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
begin
  if d like '60%' and length(d) >= 11 then d := substr(d, 3); end if;
  d := regexp_replace(d, '^0+', '');
  if length(d) < 8 or length(d) > 11 then
    raise exception 'DOMOS: Enter a valid Malaysian mobile number, e.g. 12 345 6789.';
  end if;
  return d;
end $$;

create or replace function public._prize_json(p public.prizes, with_admin boolean default false) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', p.id, 'name', p.name, 'wheelTitle', p.wheel_title, 'wheelSub', p.wheel_sub,
    'subtitle', p.subtitle, 'category', p.category, 'icon', p.icon, 'color', p.color,
    'grand', p.grand, 'sort', p.sort_order, 'note', p.note, 'active', p.active,
    'inStock', p.remaining > 0
  ) || case when with_admin then jsonb_build_object('weight', p.weight, 'total', p.total, 'remaining', p.remaining) else '{}'::jsonb end
$$;

create or replace function public._spin_json(s public.spins) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'code', s.code, 'phone', s.phone, 'name', s.name, 'prizeId', s.prize_id, 'prizeName', s.prize_name,
    'grand', s.grand, 'date', s.spin_date, 'ts', (extract(epoch from s.created_at) * 1000)::bigint,
    'status', s.status, 'redeemedAt', (extract(epoch from s.redeemed_at) * 1000)::bigint, 'redeemedBy', s.redeemed_by
  )
$$;

create or replace function public._wheel() returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(public._prize_json(p) order by p.sort_order, p.id), '[]'::jsonb)
  from public.prizes p where p.active
$$;

-- Staff PIN check with a brute-force brake (max 20 wrong tries per 10 minutes).
-- Returns false instead of raising, so the failed attempt is actually saved.
create or replace function public._pin_ok(p_pin text) returns boolean
language plpgsql security definer set search_path = public as $$
declare ok boolean; fails int;
begin
  select count(*) into fails from public.pin_attempts where created_at > now() - interval '10 minutes';
  if fails >= 20 then raise exception 'DOMOS: Too many wrong PINs. Wait 10 minutes and try again.'; end if;
  select coalesce(p_pin, '') = s.admin_pin into ok from public.settings s where s.id = 1;
  if not coalesce(ok, false) then
    insert into public.pin_attempts default values;
    delete from public.pin_attempts where created_at < now() - interval '1 day';
    return false;
  end if;
  return true;
end $$;

-- ---------------------------------------------------------------------
-- customer functions
-- ---------------------------------------------------------------------
create or replace function public.get_public_config() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'settings', jsonb_build_object('boothNumber', s.booth_number, 'dailyLimit', s.daily_limit,
                                   'announcement', s.announcement, 'whatsapp', s.whatsapp, 'theme', s.theme),
    'prizes', public._wheel(),
    'today', public._today())
  from public.settings s where s.id = 1
$$;

create or replace function public.check_phone(p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_phone text := public._clean_phone(p_phone); v_limit int; v_used int;
begin
  select daily_limit into v_limit from public.settings where id = 1;
  select count(*) into v_used from public.spins where phone = v_phone and spin_date = public._today();
  return jsonb_build_object('phone', v_phone, 'limit', v_limit, 'used', v_used, 'remaining', greatest(0, v_limit - v_used));
end $$;

create or replace function public.spin(p_phone text, p_name text default '', p_device text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_phone text := public._clean_phone(p_phone);
  v_today date := public._today();
  v_limit int; v_used int; v_total int; v_r double precision;
  v_prize public.prizes; v_code text; v_tries int := 0;
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  -- One spin at a time per phone number (stops double taps and two iPads racing).
  perform pg_advisory_xact_lock(hashtext('domos-spin:' || v_phone));

  select daily_limit into v_limit from public.settings where id = 1;
  select count(*) into v_used from public.spins where phone = v_phone and spin_date = v_today;
  if v_used >= v_limit then
    raise exception 'DOMOS: This number has already used today''s spin.';
  end if;

  -- Lock the prize rows so stock can never go below zero, even with many devices.
  perform 1 from public.prizes where active for update;

  select coalesce(sum(weight), 0) into v_total from public.prizes where active and remaining > 0 and weight > 0;
  if v_total = 0 then
    raise exception 'DOMOS: All rewards have been given out. Please see a DOMOS consultant.';
  end if;

  v_r := random() * v_total;
  select * into v_prize from public.prizes where id = (
    select c.id from (
      select pr.id, sum(pr.weight) over (order by pr.sort_order, pr.id) as cum
      from public.prizes pr where pr.active and pr.remaining > 0 and pr.weight > 0
    ) c where c.cum > v_r order by c.cum limit 1);

  update public.prizes set remaining = remaining - 1, updated_at = now() where id = v_prize.id;

  loop
    v_code := 'DOMOS-';
    for i in 1..6 loop v_code := v_code || substr(alphabet, 1 + floor(random() * 32)::int, 1); end loop;
    begin
      insert into public.spins (code, phone, name, prize_id, prize_name, grand, spin_date, device)
      values (v_code, v_phone, left(coalesce(trim(p_name), ''), 60), v_prize.id, v_prize.name, v_prize.grand, v_today, left(coalesce(p_device, ''), 180));
      exit;
    exception when unique_violation then
      v_tries := v_tries + 1;
      if v_tries > 5 then raise; end if;
    end;
  end loop;

  return jsonb_build_object(
    'prize', public._prize_json(v_prize),
    'code', v_code,
    'phone', v_phone,
    'ts', (extract(epoch from now()) * 1000)::bigint,
    'remaining', greatest(0, v_limit - v_used - 1),
    'limit', v_limit,
    -- The exact wheel the result was drawn on, so the browser draws the same segments.
    'wheel', public._wheel()
  );
end $$;

create or replace function public.my_history(p_phone text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', s.code, 'prizeName', s.prize_name, 'status', s.status,
                                               'ts', (extract(epoch from s.created_at) * 1000)::bigint) order by s.created_at desc), '[]'::jsonb)
  from public.spins s where s.phone = public._clean_phone(p_phone)
$$;

-- ---------------------------------------------------------------------
-- staff functions (all require the PIN; a wrong PIN returns {"error": ...})
-- ---------------------------------------------------------------------
create or replace function public.staff_login(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin if not public._pin_ok(p_pin) then return jsonb_build_object('error', 'DOMOS: That PIN is incorrect.'); end if; return jsonb_build_object('ok', true); end $$;

create or replace function public.staff_dashboard(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public._pin_ok(p_pin) then return jsonb_build_object('error', 'DOMOS: That PIN is incorrect.'); end if;
  return jsonb_build_object(
    'settings', (select jsonb_build_object('boothNumber', booth_number, 'dailyLimit', daily_limit, 'announcement', announcement,
                                           'whatsapp', whatsapp, 'adminPin', admin_pin, 'theme', theme) from public.settings where id = 1),
    'prizes', (select coalesce(jsonb_agg(public._prize_json(p, true) order by p.sort_order, p.id), '[]'::jsonb) from public.prizes p),
    'spins', (select coalesce(jsonb_agg(public._spin_json(s) order by s.created_at desc), '[]'::jsonb)
              from (select * from public.spins order by created_at desc limit 2000) s),
    'stats', jsonb_build_object(
      'today', (select count(*) from public.spins where spin_date = public._today()),
      'total', (select count(*) from public.spins),
      'people', (select count(distinct phone) from public.spins),
      'redeemed', (select count(*) from public.spins where status = 'redeemed'),
      'date', public._today()));
end $$;

create or replace function public.staff_save_prize(p_pin text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id text := nullif(p->>'id', ''); v_total int := greatest(0, coalesce((p->>'total')::int, 0));
begin
  if not public._pin_ok(p_pin) then return jsonb_build_object('error', 'DOMOS: That PIN is incorrect.'); end if;
  if coalesce(trim(p->>'name'), '') = '' then return jsonb_build_object('error', 'DOMOS: Give the prize a name.'); end if;
  if v_id is null or not exists (select 1 from public.prizes where id = v_id) then
    insert into public.prizes (name) values (trim(p->>'name')) returning id into v_id;
  end if;
  update public.prizes set
    name = trim(p->>'name'),
    wheel_title = coalesce(p->>'wheelTitle', ''), wheel_sub = coalesce(p->>'wheelSub', ''),
    subtitle = coalesce(p->>'subtitle', ''), category = coalesce(nullif(p->>'category', ''), 'Smart Home'),
    icon = coalesce(nullif(p->>'icon', ''), 'gift'), color = coalesce(nullif(p->>'color', ''), '#0284C7'),
    weight = greatest(0, coalesce((p->>'weight')::int, 0)),
    total = v_total,
    remaining = greatest(0, least(coalesce((p->>'remaining')::int, 0), v_total)),
    active = coalesce((p->>'active')::boolean, true), grand = coalesce((p->>'grand')::boolean, false),
    sort_order = coalesce((p->>'sort')::int, 0), note = coalesce(p->>'note', ''), updated_at = now()
  where id = v_id;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.staff_delete_prize(p_pin text, p_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin if not public._pin_ok(p_pin) then return jsonb_build_object('error', 'DOMOS: That PIN is incorrect.'); end if; delete from public.prizes where id = p_id; return jsonb_build_object('ok', true); end $$;

create or replace function public.staff_save_settings(p_pin text, s jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public._pin_ok(p_pin) then return jsonb_build_object('error', 'DOMOS: That PIN is incorrect.'); end if;
  if length(coalesce(s->>'adminPin', '')) < 4 then return jsonb_build_object('error', 'DOMOS: Use a PIN of at least 4 digits.'); end if;
  update public.settings set
    booth_number = coalesce(s->>'boothNumber', booth_number),
    daily_limit = least(20, greatest(1, coalesce((s->>'dailyLimit')::int, daily_limit))),
    announcement = coalesce(s->>'announcement', ''),
    whatsapp = coalesce(nullif(s->>'whatsapp', ''), whatsapp),
    admin_pin = s->>'adminPin',
    theme = case when s->>'theme' in ('luxe', 'classic', 'cyber') then s->>'theme' else theme end,
    updated_at = now()
  where id = 1;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.staff_lookup(p_pin text, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.spins;
begin
  if not public._pin_ok(p_pin) then return jsonb_build_object('error', 'DOMOS: That PIN is incorrect.'); end if;
  select * into r from public.spins where code = upper(trim(p_code));
  if not found then return jsonb_build_object('missing', true); end if;
  return public._spin_json(r);
end $$;

create or replace function public.staff_redeem(p_pin text, p_code text, p_by text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.spins;
begin
  if not public._pin_ok(p_pin) then return jsonb_build_object('error', 'DOMOS: That PIN is incorrect.'); end if;
  -- Only flips 'won' -> 'redeemed'; a second attempt returns the already-redeemed row.
  update public.spins set status = 'redeemed', redeemed_at = now(), redeemed_by = nullif(trim(p_by), '')
  where code = upper(trim(p_code)) and status = 'won' returning * into r;
  if found then return public._spin_json(r) || jsonb_build_object('justRedeemed', true); end if;
  select * into r from public.spins where code = upper(trim(p_code));
  if not found then return jsonb_build_object('missing', true); end if;
  return public._spin_json(r) || jsonb_build_object('justRedeemed', false);
end $$;

create or replace function public.staff_reset(p_pin text, p_confirm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public._pin_ok(p_pin) then return jsonb_build_object('error', 'DOMOS: That PIN is incorrect.'); end if;
  if coalesce(p_confirm, '') <> 'RESET' then return jsonb_build_object('error', 'DOMOS: Type RESET in the box to confirm.'); end if;
  delete from public.spins where true; get diagnostics n = row_count;
  update public.prizes set remaining = total, updated_at = now() where true;
  return jsonb_build_object('deleted', n);
end $$;

-- ---------------------------------------------------------------------
-- permissions: the browser may call ONLY these functions
-- ---------------------------------------------------------------------
revoke execute on function public._today(), public._clean_phone(text), public._prize_json(public.prizes, boolean),
  public._spin_json(public.spins), public._wheel(), public._pin_ok(text) from public, anon, authenticated;
revoke execute on function
  public.get_public_config(), public.check_phone(text), public.spin(text, text, text), public.my_history(text),
  public.staff_login(text), public.staff_dashboard(text), public.staff_save_prize(text, jsonb),
  public.staff_delete_prize(text, text), public.staff_save_settings(text, jsonb), public.staff_lookup(text, text),
  public.staff_redeem(text, text, text), public.staff_reset(text, text)
from public;
grant execute on function
  public.get_public_config(), public.check_phone(text), public.spin(text, text, text), public.my_history(text),
  public.staff_login(text), public.staff_dashboard(text), public.staff_save_prize(text, jsonb),
  public.staff_delete_prize(text, text), public.staff_save_settings(text, jsonb), public.staff_lookup(text, text),
  public.staff_redeem(text, text, text), public.staff_reset(text, text)
to anon, authenticated;

-- ---------------------------------------------------------------------
-- starter prizes (only inserted if the table is empty)
-- ---------------------------------------------------------------------
insert into public.prizes (id, name, wheel_title, wheel_sub, subtitle, category, icon, color, weight, total, remaining, active, grand, sort_order, note)
select * from (values
  ('p1','DOMOS Smart Glass Switch Panel (1 Gang)','Smart Switch','1 Gang Panel','Value RM 199 · Minimal Zigbee-connected design','Smart Switches','switch','#0284C7',8,20,20,true,false,1,'Show your redemption code to a DOMOS booth consultant to collect your physical reward.'),
  ('p2','RM 300 Smart Curtain System Voucher','RM 300','Curtain Voucher','Valid for whole-home motorized track or roller blind orders','Smart Curtains','curtain','#0D9488',20,100,100,true,false,2,'Redeem on a whole-home or single-product smart curtain order; the booth quote will be updated instantly.'),
  ('p3','Whole-home Smart Home Survey & Design (VIP)','VIP Plan','Whole-home Planning','Value RM 250 · Personalised in-home planning','Consultation','home','#4F46E5',35,200,200,true,false,3,'Free Klang Valley site measurement, lighting scenes, and complete Zigbee point planning.'),
  ('p4','DOMOS Signature Smart Home Gift Set','Gift Set','DOMOS Signature','Includes a metal tumbler, branded travel umbrella, and keepsakes','Merchandise','gift','#D97706',25,80,80,true,false,4,'Show your code at the booth to collect one limited-edition DOMOS gift set.'),
  ('p5','RM 500 Whole-home Smart Upgrade Voucher','RM 500','Upgrade Voucher','Instant cash discount with qualifying spend · Exhibition exclusive','Voucher','sparkles','#DB2777',10,50,50,true,false,5,'Valid for whole-home Zigbee lighting, security, and smart lock packages.'),
  ('p6','DOMOS Smart Fingerprint Lock 50% Off Voucher','Lock 50% Off','Fingerprint Lock','Exhibition grand prize · Top-tier reward','Smart Door','lock','#BE123C',2,5,5,true,true,6,'Enjoy 50% off a DOMOS flagship fingerprint/face-recognition smart lock, including installation.')
) as v(id, name, wheel_title, wheel_sub, subtitle, category, icon, color, weight, total, remaining, active, grand, sort_order, note)
where not exists (select 1 from public.prizes);
