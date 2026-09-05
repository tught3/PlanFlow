/**
 * 개발 미리보기 모드용 인메모리(in-memory) 일정 리포지토리.
 *
 * src/data/eventRepository.ts의 EventRepository와 동일한 메서드 시그니처
 * (listEvents/getEvent/createEvent/updateEvent/deleteEvent, 동일한
 * RepositoryResult<T> 반환 형태)를 구현해, router.tsx가 실제
 * eventRepository 대신 이 인스턴스를 그대로 주입할 수 있게 한다.
 *
 * Supabase/네트워크를 전혀 호출하지 않는다 - 시드 데이터는 메모리 배열에만
 * 있고, create/update/delete는 그 배열만 변형한다. secret/서비스 키/토스
 * 인증정보를 참조하지 않는다.
 *
 * 시드 날짜는 절대 날짜를 하드코딩하지 않고 "오늘(KST) 기준 상대 오프셋"으로
 * 계산한다 - 이 저장소의 시간의존 데이터 관례(anti-patterns.md "시간의존
 * 테스트에 절대 날짜 하드코딩 금지")를 그대로 따른 것으로, 절대 날짜였다면
 * 시간이 지나 과거가 될수록 월간/주간 뷰의 "이번 달/이번 주" 화면에서 미리보기
 * 데이터가 점점 안 보이게 됐을 것이다.
 */
import type { Event } from '../../domain/event.ts';
import type {
  EventDateRange,
  EventRepository,
  NewEventInput,
  RepositoryResult,
} from '../../data/eventRepository.ts';
import { kstDayStart, addKstDays } from '../../domain/datetime.ts';
import { DEV_PREVIEW_USER_ID } from './devPreview.ts';

let seedIdCounter = 0;

function nextSeedId(): string {
  seedIdCounter += 1;
  return `dev-preview-event-${seedIdCounter}`;
}

/** kstDayStart(오늘)에서 dayOffset일 뒤, KST hour:minute 시각. */
function atOffset(dayOffset: number, hour = 0, minute = 0): Date {
  const dayStart = kstDayStart(addKstDays(new Date(), dayOffset));
  return new Date(dayStart.getTime() + hour * 60 * 60 * 1000 + minute * 60 * 1000);
}

function baseSeedEvent(overrides: Partial<Event>): Event {
  return {
    id: nextSeedId(),
    userId: DEV_PREVIEW_USER_ID,
    title: '(제목 없음)',
    startAt: atOffset(0, 9, 0),
    endAt: null,
    location: null,
    locationLat: null,
    locationLng: null,
    memo: null,
    supplies: [],
    participants: [],
    targets: [],
    isCritical: false,
    useStrongAlarm: false,
    recurrenceRule: null,
    recurrenceEndDate: null,
    recurrenceCount: null,
    isAllDay: false,
    isMultiDay: false,
    parentEventId: null,
    overriddenOccurrenceDate: null,
    category: '기타',
    source: 'manual',
    createdAt: null,
    updatedAt: null,
    ...overrides,
  };
}

/**
 * 시드 일정 6건: 일반/중요/종일/반복/다일/일반(과거) - 오늘을 기준으로
 * 월간·주간 뷰 양쪽에서 대표 케이스를 바로 확인할 수 있게 구성했다.
 */
function createSeedEvents(): Event[] {
  return [
    baseSeedEvent({
      title: '팀 스탠드업',
      startAt: atOffset(0, 10, 0),
      endAt: atOffset(0, 10, 30),
      category: '업무',
    }),
    baseSeedEvent({
      title: '분기 보고 마감',
      startAt: atOffset(1, 18, 0),
      endAt: atOffset(1, 19, 0),
      isCritical: true,
      useStrongAlarm: true,
      category: '업무',
    }),
    baseSeedEvent({
      title: '연차',
      startAt: atOffset(3, 0, 0),
      endAt: atOffset(4, 0, 0),
      isAllDay: true,
      category: '개인',
    }),
    baseSeedEvent({
      title: '주간 회의',
      startAt: atOffset(-2, 14, 0),
      endAt: atOffset(-2, 15, 0),
      recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO',
      category: '업무',
    }),
    baseSeedEvent({
      title: '워크숍(1박 2일)',
      startAt: atOffset(5, 9, 0),
      endAt: atOffset(6, 18, 0),
      isMultiDay: true,
      location: '강원도 평창',
      category: '업무',
    }),
    baseSeedEvent({
      title: '지난 병원 예약',
      startAt: atOffset(-5, 15, 0),
      endAt: atOffset(-5, 15, 30),
      category: '개인',
    }),
  ];
}

/** listEvents(range)와 동일한 겹침 판정: end_at.gte.start 또는 (end_at is null and start_at.gte.start). */
function overlapsRange(event: Event, range: EventDateRange): boolean {
  const rangeStart = new Date(range.start).getTime();
  const rangeEnd = new Date(range.end).getTime();
  if (event.startAt.getTime() > rangeEnd) {
    return false;
  }
  if (event.endAt !== null) {
    return event.endAt.getTime() >= rangeStart;
  }
  return event.startAt.getTime() >= rangeStart;
}

function toNewEvent(input: NewEventInput, id: string): Event {
  return {
    ...input,
    id,
    createdAt: new Date(),
    updatedAt: new Date(),
  };
}

/**
 * 인메모리 EventRepository를 새로 만든다(호출마다 독립된 시드 상태) - 테스트에서
 * 여러 인스턴스를 격리해 쓸 수 있도록 팩토리 함수로 노출한다. 앱 코드는 아래
 * previewRepository 싱글턴을 쓴다(eventRepository 싱글턴과 동일한 패턴).
 */
export function createPreviewRepository(): EventRepository {
  let events: Event[] = createSeedEvents();

  return {
    async listEvents(range: EventDateRange): Promise<RepositoryResult<Event[]>> {
      const matched = events
        .filter((event) => overlapsRange(event, range))
        .slice()
        .sort((a, b) => a.startAt.getTime() - b.startAt.getTime());
      return { data: matched, error: null };
    },

    async getEvent(id: string): Promise<RepositoryResult<Event>> {
      const found = events.find((event) => event.id === id) ?? null;
      return { data: found, error: null };
    },

    async createEvent(input: NewEventInput): Promise<RepositoryResult<Event>> {
      const created = toNewEvent(input, nextSeedId());
      events = [...events, created];
      return { data: created, error: null };
    },

    async updateEvent(id: string, patch: Partial<Event>): Promise<RepositoryResult<Event>> {
      const index = events.findIndex((event) => event.id === id);
      if (index === -1) {
        return { data: null, error: { message: '일정을 찾을 수 없습니다.' } };
      }
      const updated: Event = { ...events[index], ...patch, id, updatedAt: new Date() };
      events = [...events.slice(0, index), updated, ...events.slice(index + 1)];
      return { data: updated, error: null };
    },

    async deleteEvent(id: string): Promise<RepositoryResult<null>> {
      events = events.filter((event) => event.id !== id);
      return { data: null, error: null };
    },
  };
}

/** 앱 코드(router.tsx)가 개발 미리보기 모드에서 그대로 주입해 쓰는 싱글턴. */
export const previewRepository = createPreviewRepository();
