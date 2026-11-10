import { useState } from 'react';
import { timeAgo, domainOf, translateStory, type HNItem } from '@hackdigest/core';
import { useI18n } from '../i18n';
import { useUI, useSettings, useTrans } from '../state/store';
import { IconStar, IconTranslate } from './icons';

interface Props {
  item: HNItem;
  rank?: number;
  idx?: number;
  selected?: boolean;
  read?: boolean;
  bookmarked?: boolean;
  onToggleBookmark?: (id: number) => void;
}

export default function StoryRow({ item, rank, idx, selected, read, bookmarked, onToggleBookmark }: Props) {
  const { t, lang } = useI18n();
  const navigate = useUI((s) => s.navigate);
  const llm = useSettings((s) => s.settings.llm);
  const target = useSettings((s) => s.settings.translateTarget);
  const put = useTrans((s) => s.put);
  const trans = useTrans((s) => s.map[item.id]);
  const [busy, setBusy] = useState(false);

  const domain = domainOf(item.url);
  const titleTranslated = trans?.title && trans.title !== item.title;

  const quickTranslate = async (e: React.MouseEvent) => {
    e.stopPropagation();
    if (!llm) return navigate({ type: 'settings' });
    if (busy) return;
    setBusy(true);
    try {
      const r = await translateStory(llm, item, target);
      put(item.id, r);
    } catch {
      /* surfaced on the detail page; the row stays silent */
    } finally {
      setBusy(false);
    }
  };

  return (
    <div
      data-rank={idx}
      tabIndex={selected ? -1 : undefined}
      className={`group flex cursor-pointer gap-3 border-b border-line/60 px-4 py-3 transition-colors hover:bg-raised/60 focus-visible:outline-none focus-visible:bg-raised ${
        selected ? 'bg-raised shadow-[inset_2px_0_0_0_var(--accent)]' : ''
      }`}
      onClick={() => navigate({ type: 'story', id: item.id })}
    >
      {rank != null && (
        <div
          className={`w-6 shrink-0 pt-0.5 text-right text-[13px] font-semibold tabular-nums ${
            selected ? 'text-accent' : 'text-mute'
          }`}
        >
          {rank}
        </div>
      )}
      <div className="min-w-0 flex-1">
        {/* Original title stays primary; the translation slots in below it
            so the source is always recoverable (DESIGN.md 不变式 4). */}
        <div className={`text-[15px] font-semibold leading-snug ${read ? 'text-mute' : 'text-ink'}`}>
          {item.title}
        </div>
        {titleTranslated && (
          <div className="mt-0.5 text-[14px] font-medium leading-snug text-ink/90">{trans!.title}</div>
        )}
        <div className="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-mute">
          {item.score != null && (
            <span className="tabular-nums">▲ {item.score}</span>
          )}
          <span>{timeAgo(item.time, lang)}</span>
          {item.by && <span>{item.by}</span>}
          {domain && <span className="rounded bg-raised px-1.5 py-px">{domain}</span>}
          {item.descendants != null && item.descendants > 0 && (
            <span>
              {item.descendants} {t.comments}
            </span>
          )}
          {read && <span className="text-mute/60">{t.readMark}</span>}
        </div>
        {(titleTranslated || busy) && (
          <div className="mt-1.5 flex items-center gap-1.5">
            {titleTranslated && (
              <span className="rounded-full bg-raised px-2 py-0.5 text-[11px] font-semibold text-mute">
                {t.translated}
              </span>
            )}
            {busy && (
              <span className="inline-flex items-center gap-1.5 rounded-full bg-accentsoft px-2 py-0.5 text-[11px] font-semibold text-accent">
                <IconTranslate className="animate-spin" width={11} height={11} />
                {t.translating}…
              </span>
            )}
          </div>
        )}
      </div>
      <div className="flex shrink-0 items-start gap-1 pt-0.5">
        <button
          title={t.translate}
          className="rounded-md p-1.5 text-mute opacity-0 transition-opacity hover:bg-raised hover:text-accent group-hover:opacity-100 focus:opacity-100"
          onClick={quickTranslate}
        >
          <IconTranslate className={busy ? 'animate-spin' : ''} width={14} height={14} />
        </button>
        <button
          title={bookmarked ? t.bookmarkRemoved : t.bookmarkAdded}
          className={`rounded-md p-1.5 transition-colors hover:bg-raised ${bookmarked ? 'text-accent' : 'text-mute'}`}
          onClick={(e) => {
            e.stopPropagation();
            onToggleBookmark?.(item.id);
          }}
        >
          <IconStar filled={bookmarked} width={14} height={14} />
        </button>
      </div>
    </div>
  );
}
