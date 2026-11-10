// '?' overlay: keyboard cheat sheet.

import { useI18n } from '../i18n';

const K = ({ k, label }: { k: string; label: string }) => (
  <div className="flex items-center justify-between gap-6 py-1">
    <kbd className="rounded-md border border-line bg-raised px-2 py-0.5 font-mono text-[11px] text-ink">{k}</kbd>
    <span className="text-xs text-ink/80">{label}</span>
  </div>
);

export default function ShortcutsOverlay({ onClose }: { onClose: () => void }) {
  const { t } = useI18n();
  return (
    <div className="fixed inset-0 z-[90] flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div
        className="w-full max-w-lg rounded-[10px] border border-line bg-surface p-6 shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-sm font-semibold">{t.shortcutsTitle}</h2>
          <button className="rounded-md px-2 py-0.5 text-xs text-mute hover:text-ink" onClick={onClose}>
            Esc
          </button>
        </div>
        <div className="grid grid-cols-1 gap-x-8 sm:grid-cols-2">
          <div>
            <div className="mb-1 text-[11px] font-medium uppercase tracking-wider text-mute">{t.shortcutsList}</div>
            <K k="j / ↓" label={t.sk_next} />
            <K k="k / ↑" label={t.sk_prev} />
            <K k="Enter / o" label={t.sk_open} />
            <K k="s" label={t.sk_star} />
            <K k="t" label={t.sk_translate} />
            <K k="r" label={t.sk_refresh} />
            <K k="1 – 6" label={t.sk_feeds} />
          </div>
          <div>
            <div className="mb-1 text-[11px] font-medium uppercase tracking-wider text-mute">{t.shortcutsDetail}</div>
            <K k="← / u" label={t.sk_back} />
            <K k="t" label={t.sk_translateStory} />
            <K k="T (Shift)" label={t.sk_translateAll} />
            <K k="d" label={t.sk_digest} />
            <div className="mt-3 mb-1 text-[11px] font-medium uppercase tracking-wider text-mute">{t.shortcutsGlobal}</div>
            <K k="/" label={t.sk_search} />
            <K k="?" label={t.sk_help} />
          </div>
        </div>
      </div>
    </div>
  );
}
