alter table if exists public.pre_actions
  add column if not exists source text;

update public.pre_actions
set source = 'external_preparation'
where source is null
  and (
    title in (
      '10분 뒤부터 준비 시작하세요 🔔',
      '30분 뒤부터 준비 시작하세요 🔔',
      '지금 준비 시작하세요 🚿',
      '10분 뒤 출발해야 해요 🔔',
      '30분 뒤 출발해야 해요 🔔',
      '지금 준비 시작하세요 🚿 / 10분 뒤 출발해야 해요 🔔',
      '지금 준비 시작하세요 🚿 / 30분 뒤 출발해야 해요 🔔'
    )
    or title like '지금 출발하세요 🚗 (%'
  );

create or replace function public.infer_pre_action_source()
returns trigger
language plpgsql
as $$
begin
  if new.source is null
    and (
      new.title in (
        '10분 뒤부터 준비 시작하세요 🔔',
        '30분 뒤부터 준비 시작하세요 🔔',
        '지금 준비 시작하세요 🚿',
        '10분 뒤 출발해야 해요 🔔',
        '30분 뒤 출발해야 해요 🔔',
        '지금 준비 시작하세요 🚿 / 10분 뒤 출발해야 해요 🔔',
        '지금 준비 시작하세요 🚿 / 30분 뒤 출발해야 해요 🔔'
      )
      or new.title like '지금 출발하세요 🚗 (%'
    ) then
    new.source := 'external_preparation';
  end if;
  return new;
end;
$$;

drop trigger if exists pre_actions_infer_source on public.pre_actions;
create trigger pre_actions_infer_source
  before insert or update of title, source
  on public.pre_actions
  for each row
  execute function public.infer_pre_action_source();
