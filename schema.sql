-- 僅在新 Supabase 專案的 SQL Editor 執行一次。
begin;
create table public.event_settings (id boolean primary key default true check(id), booking_open boolean not null default false, applications_open boolean not null default false);
insert into public.event_settings(id) values(true);
create table public.venues (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 name text not null check(char_length(name) between 2 and 80), district text not null check(district in ('中正區','大同區','中山區','松山區','大安區','萬華區','信義區','士林區','北投區','內湖區','南港區','文山區')),
 address text not null check(char_length(address) between 5 and 160), lat double precision not null check(lat between 24.95 and 25.22), lng double precision not null check(lng between 121.43 and 121.70),
 capacity integer not null check(capacity between 1 and 500), hours text not null check(char_length(hours) between 1 and 80), terms text not null check(char_length(terms) between 1 and 160), contact text not null check(char_length(contact) between 5 and 100),
 status text not null default 'pending' check(status in ('pending','approved','suspended','rejected')), created_at timestamptz not null default now(), unique(owner_id));
create table public.bookings (id uuid primary key default gen_random_uuid(), venue_id uuid not null references public.venues(id), user_id uuid not null references auth.users(id), seats int not null check(seats between 1 and 4), status text not null default 'active' check(status in ('active','cancelled')), created_at timestamptz not null default now());
create unique index one_active_booking on public.bookings(user_id) where status='active';
create index bookings_by_venue on public.bookings(venue_id) where status='active';
create table public.audit_log(id bigint generated always as identity primary key, table_name text not null, action text not null, actor uuid, row_id text, occurred_at timestamptz default now());
alter table public.event_settings enable row level security;
alter table public.venues enable row level security;
alter table public.bookings enable row level security;
alter table public.audit_log enable row level security;
revoke all on public.event_settings,public.venues,public.bookings,public.audit_log from anon,authenticated;
-- 只有資料庫管理員可直接操作；公開網站只能執行下方列出的函式。
create function public.log_event_change() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into public.audit_log(table_name,action,actor,row_id) values(TG_TABLE_NAME,TG_OP,auth.uid(),case when TG_OP='DELETE' then to_jsonb(old)->>'id' else to_jsonb(new)->>'id' end); if TG_OP='DELETE' then return old; end if; return new; end; $$;
create trigger venue_log after insert or update or delete on public.venues for each row execute function public.log_event_change();
create trigger booking_log after insert or update or delete on public.bookings for each row execute function public.log_event_change();
create trigger setting_log after update on public.event_settings for each row execute function public.log_event_change();
create function public.require_verified_phone() returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); begin if u is null or not exists(select 1 from auth.users where id=u and phone_confirmed_at is not null and phone ~ '^\+?8869[0-9]{8}$') then raise exception '請先使用台灣手機完成驗證'; end if; return u; end; $$;
create function public.list_venues() returns table(id uuid,name text,district text,address text,lat double precision,lng double precision,capacity integer,booked integer,hours text,terms text) language sql stable security definer set search_path='' as $$ select v.id,v.name,v.district,v.address,v.lat,v.lng,v.capacity,coalesce(sum(b.seats),0)::integer,v.hours,v.terms from public.venues v left join public.bookings b on b.venue_id=v.id and b.status='active' where v.status='approved' group by v.id order by v.district,v.name $$;
create function public.public_settings() returns table(booking_open boolean,applications_open boolean) language sql stable security definer set search_path='' as $$ select s.booking_open,s.applications_open from public.event_settings s where id=true $$;
create function public.submit_venue(p_name text,p_district text,p_address text,p_lat double precision,p_lng double precision,p_capacity int,p_hours text,p_terms text,p_contact text) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=public.require_verified_phone(); v uuid; opened boolean; begin select applications_open into opened from public.event_settings where id=true for share; if opened is distinct from true then raise exception '店家報名尚未開放'; end if; insert into public.venues(owner_id,name,district,address,lat,lng,capacity,hours,terms,contact) values(u,trim(p_name),p_district,trim(p_address),p_lat,p_lng,p_capacity,trim(p_hours),trim(p_terms),trim(p_contact)) returning id into v; return v; exception when unique_violation then raise exception '此手機已送出店家報名，請聯絡管理員'; end; $$;
create function public.reserve_seats(p_venue uuid,p_seats int) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=public.require_verified_phone(); v public.venues%rowtype; used int; bid uuid; opened boolean; begin if p_seats is null or p_seats not between 1 and 4 then raise exception '每筆限一至四位'; end if; select booking_open into opened from public.event_settings where id=true for share; if opened is distinct from true then raise exception '目前暫停預訂'; end if; select * into v from public.venues where id=p_venue for update; if not found or v.status<>'approved' then raise exception '店家未開放預訂'; end if; if (select count(*) from public.bookings where user_id=u and created_at>now()-interval '1 hour')>=5 then raise exception '操作過於頻繁，請稍後再試'; end if; select coalesce(sum(seats),0) into used from public.bookings where venue_id=v.id and status='active'; if used+p_seats>v.capacity then raise exception '剩餘座位不足'; end if; insert into public.bookings(venue_id,user_id,seats) values(v.id,u,p_seats) returning id into bid; return bid; exception when unique_violation then raise exception '每個帳號限一筆有效預訂，請先取消原預訂'; end; $$;
create function public.my_bookings() returns table(id uuid,name text,address text,seats int,status text,created_at timestamptz) language sql stable security definer set search_path='' as $$ select b.id,v.name,v.address,b.seats,b.status,b.created_at from public.bookings b join public.venues v on v.id=b.venue_id where b.user_id=auth.uid() order by b.created_at desc limit 30 $$;
create function public.cancel_booking(p_id uuid) returns boolean language plpgsql security definer set search_path='' as $$ begin update public.bookings set status='cancelled' where id=p_id and user_id=public.require_verified_phone() and status='active'; return found; end; $$;
revoke all on function public.log_event_change(),public.require_verified_phone(),public.list_venues(),public.public_settings(),public.submit_venue(text,text,text,double precision,double precision,int,text,text,text),public.reserve_seats(uuid,int),public.my_bookings(),public.cancel_booking(uuid) from public,anon,authenticated;
grant execute on function public.list_venues(),public.public_settings() to anon,authenticated;
grant execute on function public.submit_venue(text,text,text,double precision,double precision,int,text,text,text),public.reserve_seats(uuid,int),public.my_bookings(),public.cancel_booking(uuid) to authenticated;
commit;
-- 測試及驗證設定完成後，才由管理員手動開放：
-- update public.event_settings set applications_open=true, booking_open=true where id=true;