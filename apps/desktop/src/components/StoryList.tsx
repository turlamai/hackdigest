// Feed page: ranked list with progressive item loading + infinite scroll.

import { useEffect, useMemo, useRef, useState } from 'react';
import { fetchFeedIds, fetchItems, timeAgo, type FeedId, type HNItem } from '@hackdigest/core';
import { useI18n } from '../i18n';
import { useUI } from '../state/store';
import { useSentinel } from '../lib/hooks';
import { isTypingTarget } from '../lib/keys';
import { translateStory, translateTitles } from '@hackdigest/core';
import { useSettings, useTrans } from '../state/store';
import { listBookmarks, listReadIds, toggleBookmark, type BookmarkEntry } from '../lib/bookmarks';
import StoryRow from './StoryRow';
import { IconRefresh, IconSearch, IconTranslate } from './icons';

const PAGE = 30;

export default function StoryList({ feed, active = true }: { feed: FeedId; active?: boolean }) {
  const { t, lang } = useI18n();
  const [ids, setIds] = useState<number[] | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [visible, setVisible] = useState(PAGE);
  const [items, setItems] = useState<HNItem[]>([]);
  const [readIds, setReadIds] = useState<Set<number>>(new Set());
  const [bookmarks, setBookmarks] = useState<Set<number>>(new Set());
  const [tick, setTick] = useState(0);
  const [sel, setSel] = useState(0);
  const [query, setQuery] = useState('');
  const [lastLoaded, setLastLoaded] = useState<number | null>(null);
  const [busyTitles, setBusyTitles] = useState(false);
  const llm = useSettings((st) => st.settings.llm);
  const sc = useSettings((st) => st.settings.shortcuts);
  const autoTitles = useSettings((st) => st.settings.autoTranslateTitles);
  const target = useSettings((st) => st.settings.translateTarget);
  const put = useTrans((st) => st.put);
  const navigate = useUI((st) => st.navigate);

  useEffect(() => {
    let alive = true;
    setIds(null);
    setError(null);
    setVisible(PAGE);
    setItems([]);
    listReadIds().then((s) => alive && setReadIds(s));
    listBookmarks().then((b) => alive && setBookmarks(new Set(b.map((e) => e.id))));
    fetchFeedIds(feed)
      .then((r) => {
        if (alive) {
          setIds(r);
          setLastLoaded(Date.now() / 1000);
        }
      })
      .catch((e: Error) => alive && setError(e));
    return () => {
      alive = false;
    };
  }, [feed, tick]);

  useEffect(() => {
    if (!ids) return;
    let alive = true;
    const slice = ids.slice(0, visible);
    fetchItems(slice).then(async (got) => {
      const fresh = got.filter((x): x is HNItem => x != null);
      if (alive) setItems(fresh);
      // Auto-translate this batch's titles (one request per 30 rows).
      if (alive && autoTitles && llm) {
        try {
          await translateTitles(llm, fresh, target, (results) => {
            for (const [id, title] of results) {
              if (alive) put(id, { title });
            }
          });
        } catch {
          /* silent — rows keep English, hover/t still works */
        }
      }
    });
    return () => {
      alive = false;
    };
  }, [ids, visible, autoTitles, llm, target, put]);


  // HN-style keyboard navigation: j/k move, Enter/o open, s star, t translate, r refresh.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // The list stays mounted (hidden) while a story detail is open; the
      // visible view owns the keyboard.
      if (!active || isTypingTarget(e) || e.metaKey || e.ctrlKey || e.altKey) return;
      const k = e.key;
      if (k === sc.listNext || e.key === 'ArrowDown') {
        setSel((i) => Math.min(i + 1, items.length - 1));
        e.preventDefault();
      } else if (k === sc.listPrev || e.key === 'ArrowUp') {
        setSel((i) => Math.max(i - 1, 0));
        e.preventDefault();
      } else if (e.key === 'Enter' || k === sc.listOpen) {
        const it = items[sel];
        if (it) navigate({ type: 'story', id: it.id });
      } else if (k === sc.listStar) {
        const it = items[sel];
        if (it) void toggleBookmark(it.id);
      } else if (k === sc.listTranslate) {
        const it = items[sel];
        if (it && llm) void translateStory(llm, it, target).then((r) => put(it.id, r)).catch(() => {});
      } else if (k === sc.listRefresh) {
        setTick((x) => x + 1);
      } else return;
      if (e.key !== 'Enter') requestAnimationFrame(() => {
        document.querySelector('[data-rank="' + sel + '"]')?.scrollIntoView({ block: 'nearest' });
      });
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [active, items, sel, llm, target, put, navigate, sc]);

  const sentinel = useSentinel(
    () => setVisible((v) => (ids && v < ids.length ? v + PAGE : v)),
    !!ids && visible < (ids?.length ?? 0)
  );

  // Header button: batch-translate every visible title through the same
  // pipeline the auto-translate effect uses (one request per 30 rows).
  const translateVisible = async () => {
    if (!llm) return navigate({ type: 'settings' });
    if (busyTitles) return;
    setBusyTitles(true);
    try {
      await translateTitles(llm, items, target, (results) => {
        for (const [id, title] of results) put(id, { title });
      });
    } catch {
      /* rows keep English — per-row `t` still works */
    } finally {
      setBusyTitles(false);
    }
  };

  // Keyboard continuity across detail/back: when the list becomes visible
  // again, put focus on the selected row (rows are programmatic targets,
  // not tab stops — j/k/Enter remain the list's keyboard interface).
  const wasActive = useRef(!active);
  useEffect(() => {
    if (active && !wasActive.current) {
      wasActive.current = true;
      requestAnimationFrame(() => {
        const row = document.querySelector<HTMLElement>('[data-rank="' + sel + '"]');
        row?.focus();
      });
    } else if (!active) {
      wasActive.current = false;
    }
  }, [active, sel]);

  const rankBase = useMemo(() => 1, []);

  if (error)
    return (
      <div className="p-8 text-center text-mute">
        {t.loadFail} — {error.message}
        <button className="ml-3 text-accent underline" onClick={() => setTick((x) => x + 1)}>
          {t.retry}
        </button>
      </div>
    );
  if (!ids) return <div className="p-8 text-center text-mute">{t.loading}</div>;

  return (
    <div>
      <div className="sticky top-0 z-10 border-b border-line bg-bg/90 px-5 py-3 backdrop-blur">
        <div className="flex items-center gap-3">
          <h1 className="text-[17px] font-bold leading-tight">{t.feeds[feed]}</h1>
          {lastLoaded != null && (
            <div className="truncate text-xs text-mute">
              {t.updatedAt.replace('{time}', timeAgo(lastLoaded, lang))}
            </div>
          )}
          <div className="flex-1" />
          <div className="flex h-[30px] w-60 items-center gap-2 rounded-md border border-line bg-surface px-2.5 text-[13px] text-mute focus-within:ring-1 focus-within:ring-accent/50">
            <IconSearch width={13} height={13} className="shrink-0" />
            <input
              id="global-search"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && query.trim()) {
                  navigate({ type: 'search', query: query.trim() });
                  setQuery('');
                }
              }}
              placeholder={t.searchPlaceholder}
              className="w-full bg-transparent text-ink outline-none placeholder:text-mute"
            />
          </div>
          <button
            className="flex h-[30px] items-center gap-1.5 rounded-md border border-line bg-surface px-3 text-xs font-semibold text-ink hover:bg-raised"
            onClick={() => setTick((x) => x + 1)}
          >
            <IconRefresh width={13} height={13} />
            {t.refresh}
          </button>
          <button
            className={`flex h-[30px] items-center gap-1.5 rounded-md border px-3 text-xs font-semibold transition-colors ${
              busyTitles
                ? 'border-line bg-raised text-mute'
                : 'border-transparent bg-accentsoft text-accent hover:bg-accentsoft/70'
            }`}
            onClick={() => void translateVisible()}
          >
            <IconTranslate className={busyTitles ? 'animate-spin' : ''} width={13} height={13} />
            {busyTitles ? `${t.translating}…` : t.translatePage}
          </button>
        </div>
      </div>
      {items.map((item, i) => (
        <StoryRow
          key={item.id}
          item={item}
          rank={rankBase + i}
          idx={i}
          selected={sel === i}
          read={readIds.has(item.id)}
          bookmarked={bookmarks.has(item.id)}
          onToggleBookmark={async (id) => {
            const now = await toggleBookmark(id);
            setBookmarks((prev) => {
              const next = new Set(prev);
              if (now) next.add(id);
              else next.delete(id);
              return next;
            });
          }}
        />
      ))}
      {items.length < Math.min(visible, ids.length) && (
        <div className="p-6 text-center text-sm text-mute">{t.loading}</div>
      )}
      <div ref={sentinel} className="h-4" />
    </div>
  );
}
