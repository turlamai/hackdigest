import type { FeedId } from '@hackdigest/core';
import { useUI, useSettings } from '../state/store';
import { useI18n } from '../i18n';
import {
  IconStar,
  IconNewspaper,
  IconSettings,
  IconSun,
  IconMoon,
} from './icons';

const FEEDS: FeedId[] = ['top', 'new', 'best', 'ask', 'show', 'job'];

export default function Sidebar() {
  const { t } = useI18n();
  const view = useUI((s) => s.view);
  const navigate = useUI((s) => s.navigate);
  const settings = useSettings((s) => s.settings);
  const patch = useSettings((s) => s.patch);

  const dark = settings.theme === 'dark';
  // Native buttons: every destination is keyboard reachable (Tab) and
  // operable with Enter/Space; focus-visible keeps the focus ring visible
  // in both languages. aria-current marks the active destination for
  // assistive tech instead of relying on the color change alone.
  const itemCls = (active: boolean) =>
    `flex w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-sm text-left transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-accent ${
      active
        ? 'bg-raised font-semibold text-ink shadow-[inset_2px_0_0_0_var(--accent)]'
        : 'text-ink/75 hover:bg-raised'
    }`;
  // Feed numbers mirror the fixed 1-6 feed-switch keys (see App.tsx).
  const numCls = (active: boolean) =>
    `grid h-4 w-4 shrink-0 place-items-center rounded-sm border text-[10.5px] tabular-nums ${
      active ? 'border-accentsoft bg-accentsoft text-accent' : 'border-line bg-raised text-mute'
    }`;

  return (
    <aside className="flex h-full w-56 shrink-0 flex-col border-r border-line bg-surface px-2.5 pt-3">
      <div className="flex items-center gap-2 px-2 pb-3">
        <div className="grid h-[22px] w-[22px] shrink-0 place-items-center rounded-md bg-accent text-xs font-bold text-white">
          H
        </div>
        <div className="text-[14.5px] font-bold tracking-tight">HackDigest</div>
      </div>

      <nav className="flex-1 space-y-0.5 overflow-y-auto px-0.5" aria-label={t.sectionFeeds}>
        <div className="px-2 pb-1 pt-1 text-[11px] font-semibold uppercase tracking-wider text-mute">
          {t.sectionFeeds}
        </div>
        {FEEDS.map((f, i) => {
          const active = view.type === 'feed' && view.feed === f;
          return (
            <button
              key={f}
              type="button"
              className={itemCls(active)}
              aria-current={active ? 'page' : undefined}
              onClick={() => navigate({ type: 'feed', feed: f })}
            >
              <span className={numCls(active)}>{i + 1}</span>
              {t.feeds[f]}
            </button>
          );
        })}

        <div className="px-2 pb-1 pt-4 text-[11px] font-semibold uppercase tracking-wider text-mute">
          {t.sectionLibrary}
        </div>
        <button
          type="button"
          className={itemCls(view.type === 'daily')}
          aria-current={view.type === 'daily' ? 'page' : undefined}
          onClick={() => navigate({ type: 'daily' })}
        >
          <IconNewspaper width={14} height={14} />
          {t.daily}
        </button>
        <button
          type="button"
          className={itemCls(view.type === 'bookmarks')}
          aria-current={view.type === 'bookmarks' ? 'page' : undefined}
          onClick={() => navigate({ type: 'bookmarks' })}
        >
          <IconStar width={14} height={14} />
          {t.bookmarks}
        </button>
      </nav>

      <div className="space-y-0.5 border-t border-line pb-2 pt-2">
        <button type="button" className={itemCls(false)} onClick={() => patch({ theme: dark ? 'light' : 'dark' })}>
          {dark ? <IconSun width={14} height={14} /> : <IconMoon width={14} height={14} />}
          {dark ? t.themeLight : t.themeDark}
        </button>
        <button
          type="button"
          className={itemCls(view.type === 'settings')}
          aria-current={view.type === 'settings' ? 'page' : undefined}
          onClick={() => navigate({ type: 'settings' })}
        >
          <IconSettings width={14} height={14} />
          {t.settings}
        </button>
        <div className="flex items-center gap-2 px-2.5 pt-1.5">
          <span className={`h-[7px] w-[7px] shrink-0 rounded-full ${settings.llm ? 'bg-[#28c840]' : 'bg-line'}`} />
          <span className="truncate text-xs text-mute">{settings.llm ? t.statusReady : t.statusNoLlm}</span>
        </div>
        <div className="px-2.5 pt-0.5 text-[11px] text-mute/70">{t.footer}</div>
      </div>
    </aside>
  );
}
