// Settings section: view & rebind keyboard shortcuts (non-geek friendly).

import { useEffect, useState } from 'react';
import { DEFAULT_SHORTCUTS, type Shortcuts } from '@hackdigest/core';
import { useI18n } from '../i18n';
import { useSettings } from '../state/store';
import { toast } from './Toast';

const KEY_LABELS: Array<{ id: keyof Shortcuts; labelKey: 'sk_next' | 'sk_prev' | 'sk_open' | 'sk_star' | 'sk_translate' | 'sk_refresh' | 'sk_back' | 'sk_translateStory' | 'sk_translateAll' | 'sk_digest' }> = [
  { id: 'listNext', labelKey: 'sk_next' },
  { id: 'listPrev', labelKey: 'sk_prev' },
  { id: 'listOpen', labelKey: 'sk_open' },
  { id: 'listStar', labelKey: 'sk_star' },
  { id: 'listTranslate', labelKey: 'sk_translate' },
  { id: 'listRefresh', labelKey: 'sk_refresh' },
  { id: 'detailBack', labelKey: 'sk_back' },
  { id: 'detailTranslate', labelKey: 'sk_translateStory' },
  { id: 'detailTranslateAll', labelKey: 'sk_translateAll' },
  { id: 'detailDigest', labelKey: 'sk_digest' },
];

function displayKey(k: string): string {
  return k.length === 1 && k === k.toUpperCase() && /[A-Z]/.test(k) ? `Shift+${k}` : k.toUpperCase();
}

function KeyCapture({ value, onPick }: { value: string; onPick: (k: string) => void }) {
  const [listening, setListening] = useState(false);
  useEffect(() => {
    if (!listening) return;
    const h = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.key === 'Escape') {
        setListening(false);
        return;
      }
      if (e.key.length === 1 && /[a-zA-Z0-9]/.test(e.key)) {
        onPick(e.key);
        setListening(false);
      }
    };
    window.addEventListener('keydown', h, true);
    return () => window.removeEventListener('keydown', h, true);
  }, [listening, onPick]);

  return (
    <button
      className={`min-w-14 rounded-md border px-2 py-1 text-center font-mono text-[11px] ${
        listening ? 'border-accent bg-accentsoft text-accent' : 'border-line bg-raised text-ink hover:border-accent'
      }`}
      onClick={() => setListening((v) => !v)}
    >
      {listening ? '···' : displayKey(value)}
    </button>
  );
}

export default function ShortcutSettings() {
  const { t } = useI18n();
  const shortcuts = useSettings((s) => s.settings.shortcuts);
  const patch = useSettings((s) => s.patch);

  const pick = (id: keyof Shortcuts, key: string) => {
    const conflict = (Object.keys(shortcuts) as Array<keyof Shortcuts>).find((k) => k !== id && shortcuts[k] === key);
    if (conflict) {
      toast.error(t.skConflict.replace('{key}', displayKey(key)).replace('{action}', t[KEY_LABELS.find((x) => x.id === conflict)!.labelKey]));
      return;
    }
    patch({ shortcuts: { ...shortcuts, [id]: key } });
  };

  return (
    <section className="mt-6">
      <div className="mb-1 flex items-center justify-between border-b border-line pb-2">
        <h2 className="text-xs font-bold uppercase tracking-wider text-mute">{t.shortcutsTitle}</h2>
        <button
          className="rounded-md border border-line px-2 py-1 text-[11px] text-mute hover:text-ink"
          onClick={() => patch({ shortcuts: { ...DEFAULT_SHORTCUTS } })}
        >
          {t.skReset}
        </button>
      </div>
      <p className="mb-4 mt-2 text-xs leading-relaxed text-mute">{t.skHint}</p>
      <div className="grid grid-cols-1 gap-x-10 gap-y-1.5 sm:grid-cols-2">
        {KEY_LABELS.map(({ id, labelKey }) => (
          <div key={id} className="flex items-center justify-between gap-4 py-0.5">
            <span className="text-sm text-ink/80">{t[labelKey]}</span>
            <KeyCapture value={shortcuts[id]} onPick={(k) => pick(id, k)} />
          </div>
        ))}
      </div>
      <p className="mt-4 text-[11px] text-mute">
        {t.skFixed}: <kbd className="rounded border border-line bg-raised px-1">↑↓</kbd> {' '}
        <kbd className="rounded border border-line bg-raised px-1">Enter</kbd> {' '}
        <kbd className="rounded border border-line bg-raised px-1">←</kbd> {' '}
        <kbd className="rounded border border-line bg-raised px-1">1-6</kbd> {' '}
        <kbd className="rounded border border-line bg-raised px-1">/</kbd> {' '}
        <kbd className="rounded border border-line bg-raised px-1">?</kbd>
      </p>
    </section>
  );
}
