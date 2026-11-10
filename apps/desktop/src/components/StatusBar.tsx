// Bottom hints bar: mirrors the real, user-configurable shortcut keys for
// the active view. Purely presentational — every hint maps to an existing
// key handler, nothing here introduces new bindings.

import { useI18n } from '../i18n';
import { useSettings, useUI } from '../state/store';

export default function StatusBar() {
  const { t } = useI18n();
  const view = useUI((s) => s.view);
  const sc = useSettings((s) => s.settings.shortcuts);

  const hints: Array<[string, string]> =
    view.type === 'feed'
      ? [
          [`${sc.listNext}/${sc.listPrev}`, t.hintSelect],
          [sc.listOpen, t.hintOpen],
          [sc.listTranslate, t.hintTranslate],
          [sc.listStar, t.hintBookmark],
          [sc.listRefresh, t.hintRefresh],
          ['/', t.sk_search],
          ['?', t.sk_help],
        ]
      : view.type === 'story'
        ? [
            [`←/${sc.detailBack}`, t.hintBack],
            [sc.detailTranslate, t.hintTranslate],
            [sc.detailTranslateAll, t.sk_translateAll],
            [sc.detailDigest, t.sk_digest],
            ['?', t.sk_help],
          ]
        : [['?', t.sk_help]];

  return (
    <div className="flex h-8 flex-none items-center gap-4 overflow-hidden border-t border-line bg-surface px-5 text-xs text-mute">
      {hints.map(([keys, label]) => (
        <span key={keys} className="whitespace-nowrap">
          <kbd className="mr-1 rounded border border-line bg-raised px-1 py-px text-[10.5px]">{keys}</kbd>
          {label}
        </span>
      ))}
    </div>
  );
}
