// Settings: appearance, BYOK provider, translation target, cache, about.

import { useState, useEffect } from 'react';
import {
  apiGet,
  PROVIDERS,
  TRANSLATE_TARGETS,
  langName,
  testLLM,
  type LLMConfig,
  setKeyStorageMode,
} from '@hackdigest/core';
import { useI18n } from '../i18n';
import { useSettings, useTrans } from '../state/store';
import { openExternal } from '../lib/hooks';
import { checkForUpdate, type UpdateInfo } from '../lib/updater';
import { useUpdateFlow } from './UpdateBanner';
import ShortcutSettings from './ShortcutSettings';

// Fallback only; the backend's /api/health version overrides it.
const APP_VERSION = '0.1.0';
const REPO_URL = 'https://github.com/turinglambdaai/hackdigest';

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="rounded-xl border border-line bg-surface p-5">
      <h2 className="mb-4 text-sm font-semibold">{title}</h2>
      {children}
    </section>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="mb-3 flex items-center justify-between gap-4 text-sm">
      <span className="text-ink/80">{label}</span>
      {children}
    </label>
  );
}

const inputCls =
  'w-56 rounded-lg border border-line bg-raised px-2.5 py-1.5 text-sm outline-none focus:ring-1 focus:ring-accent/50';

export default function SettingsPage() {
  const { t } = useI18n();
  const settings = useSettings((s) => s.settings);
  const patch = useSettings((s) => s.patch);
  const clearTrans = useTrans((s) => s.clear);
  const [testState, setTestState] = useState<'idle' | 'running' | 'ok' | 'fail'>('idle');
  const [testMsg, setTestMsg] = useState('');
  const [cacheCleared, setCacheCleared] = useState(false);
  const [updateState, setUpdateState] = useState<'idle' | 'checking' | 'none' | 'found' | 'error'>('idle');
  const [update, setUpdate] = useState<UpdateInfo | null>(null);
  const flow = useUpdateFlow(update);
  const [appVersion, setAppVersion] = useState(APP_VERSION);

  // The backend reports the real packaged version (APP_VERSION above only
  // covers plain-browser dev where no backend is up).
  useEffect(() => {
    apiGet<{ version: string }>('/api/health')
      .then((j) => {
        if (j && typeof j.version === 'string') setAppVersion(j.version);
      })
      .catch(() => {});
  }, []);

  const provider = PROVIDERS.find((p) => p.id === settings.providerId);
  const llm = settings.llm ?? { baseUrl: '', apiKey: '', model: '' };

  const setLLM = (p: Partial<LLMConfig>) => patch({ llm: { ...llm, ...p } });

  const pickProvider = (id: string) => {
    const preset = PROVIDERS.find((p) => p.id === id);
    if (!preset) return;
    patch({
      providerId: id,
      llm: {
        baseUrl: preset.id === 'custom' ? '' : preset.baseUrl,
        apiKey: '',
        model: preset.defaultModel,
      },
    });
    setTestState('idle');
  };

  // Key custody (issue #2 secure-storage): keyring vs explicit plaintext
  // opt-out, switched server-side via /api/settings/key-storage.
  const [keyStorageState, setKeyStorageState] = useState<'idle' | 'busy' | 'done' | 'error'>('idle');
  const hasSavedKey = Boolean((settings.llm as { hasSavedKey?: boolean } | null)?.hasSavedKey)
    || settings.apiKeyStorage === 'keyring';
  const refreshSettings = useSettings.getState().init;
  const changeKeyStorage = async (mode: 'keyring' | 'plaintext') => {
    setKeyStorageState('busy');
    try {
      await setKeyStorageMode(mode);
      await refreshSettings();
      setKeyStorageState('done');
    } catch {
      setKeyStorageState('error');
    }
  };
  const clearSavedKey = () => {
    const { hasSavedKey: _drop, ...cleanLlm } = (settings.llm ?? { baseUrl: '', apiKey: '', model: '' }) as typeof settings.llm & { hasSavedKey?: boolean };
    patch({ llm: { baseUrl: cleanLlm.baseUrl, apiKey: '', model: cleanLlm.model } });
  };

  const runTest = async () => {
    if (!llm.baseUrl || !llm.model) return;
    setTestState('running');
    try {
      if (llm.apiKey) {
        await testLLM(llm);
      } else {
        // Ollama etc. work without a key; still probe /models.
        await testLLM({ ...llm, apiKey: 'none' });
      }
      setTestState('ok');
    } catch (e) {
      setTestState('fail');
      setTestMsg(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <div className="mx-auto max-w-2xl space-y-4 px-5 py-6">
      <Section title={t.settingsAppearance}>
        <Row label={t.language}>
          <select className={inputCls} value={settings.uiLang} onChange={(e) => patch({ uiLang: e.target.value as 'zh' | 'en' })}>
            <option value="zh">中文</option>
            <option value="en">English</option>
          </select>
        </Row>
        <Row label={t.theme}>
          <select className={inputCls} value={settings.theme} onChange={(e) => patch({ theme: e.target.value as 'light' | 'dark' | 'auto' })}>
            <option value="auto">{t.themeAuto}</option>
            <option value="light">{t.themeLight}</option>
            <option value="dark">{t.themeDark}</option>
          </select>
        </Row>
        <Row label={t.fontSize}>
          <select className={inputCls} value={settings.fontScale} onChange={(e) => patch({ fontScale: Number(e.target.value) })}>
            <option value={0.9}>90%</option>
            <option value={1}>100%</option>
            <option value={1.1}>110%</option>
            <option value={1.25}>125%</option>
          </select>
        </Row>
      </Section>

      <ShortcutSettings />

      <Section title={t.settingsAI}>
        <p className="mb-4 rounded-lg bg-raised p-3 text-xs leading-relaxed text-mute">{t.byokHint}</p>
        <Row label={t.provider}>
          <select className={inputCls} value={settings.providerId} onChange={(e) => pickProvider(e.target.value)}>
            <option value="">—</option>
            {PROVIDERS.map((p) => (
              <option key={p.id} value={p.id}>
                {p.label}
              </option>
            ))}
          </select>
        </Row>
        {provider && provider.note && <p className="mb-3 text-xs text-accent">{provider.note}</p>}
        {provider && provider.keyUrl && (
          <p className="mb-3 text-xs text-mute">
            <button className="underline hover:text-accent" onClick={() => void openExternal(provider.keyUrl!)}>
              {t.getApiKey} →
            </button>
          </p>
        )}
        {settings.providerId && (
          <>
            <Row label={t.baseUrl}>
              <input className={inputCls} value={llm.baseUrl} onChange={(e) => setLLM({ baseUrl: e.target.value.trim() })} placeholder="https://…/v1" />
            </Row>
            <Row label={t.model}>
              <input className={inputCls} value={llm.model} onChange={(e) => setLLM({ model: e.target.value.trim() })} list="model-list" />
              <datalist id="model-list">
                {provider?.models.map((m) => (
                  <option key={m} value={m} />
                ))}
              </datalist>
            </Row>
            <Row label={t.apiKey}>
              <input
                type="password"
                className={inputCls}
                value={llm.apiKey}
                onChange={(e) => setLLM({ apiKey: e.target.value.trim() })}
                placeholder="sk-…"
                autoComplete="off"
              />
            </Row>
            {settings.providerId !== 'hosted' && (
              <Row label={t.keyStorageLabel}>
                <div className="flex items-center gap-2">
                  {settings.apiKeyStorage === 'keyring' && (
                    <>
                      <span className="text-xs text-green-600 dark:text-green-400">{t.keyStorageKeyring}</span>
                      <button
                        className="rounded-lg border border-line px-2.5 py-1 text-xs text-mute hover:text-ink disabled:opacity-50"
                        disabled={keyStorageState === 'busy'}
                        onClick={() => void changeKeyStorage('plaintext')}
                      >
                        {t.keyStorageToPlaintext}
                      </button>
                    </>
                  )}
                  {settings.apiKeyStorage === 'plaintext-optout' && (
                    <>
                      <span className="text-xs text-mute">{t.keyStoragePlaintext}</span>
                      <button
                        className="rounded-lg border border-line px-2.5 py-1 text-xs text-mute hover:text-ink disabled:opacity-50"
                        disabled={keyStorageState === 'busy'}
                        onClick={() => void changeKeyStorage('keyring')}
                      >
                        {t.keyStorageToKeyring}
                      </button>
                    </>
                  )}
                  {keyStorageState === 'error' && <span className="text-xs text-mute">{t.keyStorageUnavailable}</span>}
                  {keyStorageState === 'done' && <span className="text-xs text-green-600 dark:text-green-400">{t.keyStorageMoved}</span>}
                </div>
              </Row>
            )}
            {hasSavedKey && (
              <Row label="">
                <button
                  className="rounded-lg border border-line px-2.5 py-1 text-xs text-mute hover:text-ink"
                  onClick={() => clearSavedKey()}
                >
                  {t.clearSavedKey}
                </button>
              </Row>
            )}
            <Row label={t.autoTranslateTitlesLabel}>
              <button
                className={`rounded-lg px-3 py-1.5 text-xs font-medium ${settings.autoTranslateTitles ? 'bg-accent text-white' : 'border border-line text-mute hover:text-ink'}`}
                onClick={() => patch({ autoTranslateTitles: !settings.autoTranslateTitles })}
              >
                {settings.autoTranslateTitles ? t.on : t.off}
              </button>
            </Row>
            <Row label={t.autoTranslateLabel}>
              <button
                className={`rounded-lg px-3 py-1.5 text-xs font-medium ${settings.autoTranslateOnScroll ? 'bg-accent text-white' : 'border border-line text-mute hover:text-ink'}`}
                onClick={() => patch({ autoTranslateOnScroll: !settings.autoTranslateOnScroll })}
              >
                {settings.autoTranslateOnScroll ? t.on : t.off}
              </button>
            </Row>
            <Row label={t.targetLang}>
              <select className={inputCls} value={settings.translateTarget} onChange={(e) => patch({ translateTarget: e.target.value })}>
                {TRANSLATE_TARGETS.map((l) => (
                  <option key={l} value={l}>
                    {langName(l)}
                  </option>
                ))}
              </select>
            </Row>
            <div className="mt-2 flex items-center gap-3">
              <button
                className="rounded-lg bg-accent px-3 py-1.5 text-xs font-medium text-white hover:opacity-90 disabled:opacity-50"
                onClick={runTest}
                disabled={!llm.baseUrl || !llm.model || testState === 'running'}
              >
                {t.testConn}
              </button>
              {testState === 'ok' && <span className="text-xs text-green-600 dark:text-green-400">{t.testOk}</span>}
              {testState === 'fail' && (
                <span className="text-xs text-red-600 dark:text-red-400" title={testMsg}>
                  {t.testFail}
                </span>
              )}
            </div>
          </>
        )}
      </Section>

      <Section title={t.about}>
        <Row label={t.version}>
          <span className="text-sm text-mute">v{appVersion}</span>
        </Row>
        <div className="mb-3 flex flex-wrap items-center gap-3">
          <button
            className="rounded-lg bg-accent px-3 py-1.5 text-xs font-medium text-white hover:opacity-90 disabled:opacity-50"
            disabled={updateState === 'checking' || updateState === 'found'}
            onClick={async () => {
              setUpdateState('checking');
              try {
                const found = await checkForUpdate();
                if (!found) {
                  setUpdateState('none');
                  return;
                }
                setUpdate(found);
                setUpdateState('found');
                if (found.mode === 'page') await openExternal(found.url);
              } catch {
                setUpdateState('error');
              }
            }}
          >
            {updateState === 'found' ? t.updateAvailable : t.checkUpdate}
          </button>
          {updateState === 'found' && update && update.mode !== 'page' && flow.phase === 'found' && (
            <button
              className="rounded-lg bg-accent px-3 py-1.5 text-xs font-medium text-white hover:opacity-90"
              onClick={() => void flow.download()}
            >
              {t.updateDownload}
            </button>
          )}
          {updateState === 'found' && update && flow.phase === 'downloading' && (
            <span className="text-xs text-mute">{t.updateDownloading.replace('{percent}', String(flow.percent))}</span>
          )}
          {updateState === 'found' && update && flow.phase === 'downloaded' && !update.mode.includes('manual') && (
            <button
              className="rounded-lg bg-accent px-3 py-1.5 text-xs font-medium text-white hover:opacity-90"
              onClick={() => void flow.install()}
            >
              {t.updateReadyInstall}
            </button>
          )}
          {updateState === 'found' && update && flow.phase === 'downloaded' && update.mode === 'manual' && (
            <>
              <span className="text-xs text-mute">{t.updateManualHint}</span>
              <button
                className="rounded-lg bg-accent px-3 py-1.5 text-xs font-medium text-white hover:opacity-90"
                onClick={() => void flow.install()}
              >
                {t.updateOpenFolder}
              </button>
            </>
          )}
          {updateState === 'found' && update && flow.phase === 'installing' && (
            <span className="text-xs text-mute">{t.updateInstalling}</span>
          )}
          {updateState === 'found' && update && flow.phase === 'error' && (
            <span className="text-xs text-red-600 dark:text-red-400">{t.updateFailed}</span>
          )}
          {updateState === 'found' && update && update.mode === 'page' && flow.phase === 'found' && (
            <span className="text-xs text-mute">{t.updatePageHint}</span>
          )}
          {updateState === 'none' && <span className="text-xs text-green-600 dark:text-green-400">{t.upToDate}</span>}
          {updateState === 'error' && <span className="text-xs text-red-600 dark:text-red-400">{t.updateFailed}</span>}
        </div>
        <Row label="GitHub">
          <button className="text-sm text-accent underline" onClick={() => void openExternal(REPO_URL)}>
            {t.viewRepo}
          </button>
        </Row>
        <p className="text-xs text-mute">{t.proComingSoon}</p>
        <button
          className="mt-3 rounded-lg border border-line px-3 py-1.5 text-xs text-mute hover:bg-raised hover:text-ink"
          onClick={async () => {
            const dbs = ['trans'].map((name) => indexedDB.deleteDatabase('hackdigest'));
            await Promise.all(dbs).catch(() => {});
            clearTrans();
            setCacheCleared(true);
          }}
        >
          {cacheCleared ? t.cacheCleared : t.clearTransCache}
        </button>
      </Section>
    </div>
  );
}
