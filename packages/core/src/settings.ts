// App settings: the JSON file in the OS app-config dir is the source of
// truth in packaged builds (IndexedDB there proved non-persistent and was
// wiped on updates). IndexedDB remains the store for plain-browser dev.

import type { LLMConfig } from './llm';
import { kvGet, kvSet } from './store';
import { readDataFile, writeDataFile } from './dataFile';
import { apiPost, hasBackend } from './bridge';

export interface Shortcuts {
  listNext: string;
  listPrev: string;
  listOpen: string;
  listStar: string;
  listTranslate: string;
  listRefresh: string;
  detailBack: string;
  detailTranslate: string;
  detailTranslateAll: string;
  detailDigest: string;
}

export const DEFAULT_SHORTCUTS: Shortcuts = {
  listNext: 'j',
  listPrev: 'k',
  listOpen: 'o',
  listStar: 's',
  listTranslate: 't',
  listRefresh: 'r',
  detailBack: 'u',
  detailTranslate: 't',
  detailTranslateAll: 'T',
  detailDigest: 'd',
};

export type KeyStorageMode = 'keyring' | 'plaintext-optout';

export interface Settings {
  uiLang: 'zh' | 'en';
  theme: 'light' | 'dark' | 'auto';
  translateTarget: string; // 'zh' | 'zh-TW' | 'ja' | 'ko' | 'en'
  fontScale: number; // 0.9 / 1.0 / 1.1 / 1.25
  llm: LLMConfig | null;
  providerId: string; // preset id, '' when unset
  shortcuts: Shortcuts;
  autoTranslateOnScroll: boolean;
  autoTranslateTitles: boolean;
  /** Key custody: the BYOK key lives in the system keyring ('keyring') or
   *  in plain settings after an explicit opt-out. Absent = undecided (a
   *  fresh install or no key yet); the backend migrates at startup. */
  apiKeyStorage?: KeyStorageMode;
}

export const DEFAULT_SETTINGS: Settings = {
  uiLang: 'zh',
  theme: 'auto',
  translateTarget: 'zh',
  fontScale: 1.0,
  llm: null,
  providerId: '',
  shortcuts: DEFAULT_SHORTCUTS,
  autoTranslateOnScroll: false,
  autoTranslateTitles: true,
};

export function mergeStoredSettings(raw: Partial<Settings> | null | undefined): Settings {
  // Legacy hosted-provider data remaps to a plain custom endpoint: the
  // hosted config surface (device trials, desktop activation) was removed
  // while hosted is not for sale, but an existing base URL / key / model
  // must keep working as-is. The cached hostedStatus is dropped.
  const { hostedStatus: _legacyQuota, ...rest } = (raw ?? {}) as Partial<Settings> & { hostedStatus?: unknown };
  const legacyHosted = rest.providerId === 'hosted';
  // Keyring custody keeps settings.json keyless — an absent apiKey field
  // must not surface as undefined into the page's controlled inputs.
  const llm: LLMConfig | null = rest.llm
    ? { ...rest.llm, baseUrl: rest.llm.baseUrl ?? '', apiKey: rest.llm.apiKey ?? '', model: rest.llm.model ?? '' }
    : null;
  return {
    ...DEFAULT_SETTINGS,
    ...rest,
    llm,
    providerId: legacyHosted ? 'custom' : (rest.providerId ?? ''),
    shortcuts: { ...DEFAULT_SHORTCUTS, ...(raw?.shortcuts ?? {}) },
  };
}

/** Ask the backend to move the key between the system keyring and plain
 *  settings (issue #2 secure-storage slice). Throws on refusal — e.g. no
 *  keyring available — so the page can surface the reason. */
export async function setKeyStorageMode(mode: Exclude<KeyStorageMode, never> | 'plaintext'): Promise<void> {
  if (!(await hasBackend())) throw new Error('key storage requires the backend');
  await apiPost('/api/settings/key-storage', { mode });
}

// The backend masks a stored BYOK key as this sentinel on reads. Legacy
// hosted-provider data keeps its key visible server-side (it was a license
// key, shown for display); once such a config is re-saved as a custom
// endpoint, the mask applies like any other BYOK key. The page sees an
// empty field plus this marker so an untouched save keeps the stored key.
const MASKED_KEY = '__SAVED__';

interface LLMWithMarker extends LLMConfig {
  hasSavedKey?: boolean;
}

function unmark(llm: LLMConfig | null): LLMConfig | null {
  if (llm && (llm as LLMWithMarker).apiKey === MASKED_KEY) {
    return { ...llm, apiKey: '', ...( { hasSavedKey: true } as Partial<LLMWithMarker>) };
  }
  if (llm && (llm as LLMWithMarker).hasSavedKey && llm.apiKey !== '') {
    // The user typed a new key on top of a masked read — drop the marker.
    const { hasSavedKey: _drop, ...rest } = llm as LLMWithMarker;
    return rest;
  }
  return llm;
}

function remark(llm: LLMConfig | null): LLMConfig | null {
  if (llm && (llm as LLMWithMarker).hasSavedKey && llm.apiKey === '') {
    return { ...llm, apiKey: MASKED_KEY };
  }
  return llm;
}

export async function loadSettings(): Promise<Settings> {
  if (await hasBackend()) {
    // File is the source of truth in packaged builds.
    const fromFile = await readDataFile<Partial<Settings>>('settings');
    if (fromFile) return mergeStoredSettings({ ...fromFile, llm: unmark(fromFile.llm ?? null) });
    // First run after this migration: adopt whatever IndexedDB still has.
    const saved = await kvGet<Partial<Settings>>('meta', 'settings');
    const merged = mergeStoredSettings(saved);
    if (saved) void writeDataFile('settings', merged);
    return merged;
  }
  const saved = await kvGet<Partial<Settings>>('meta', 'settings');
  return mergeStoredSettings(saved);
}

export async function saveSettings(s: Settings): Promise<void> {
  if (await hasBackend()) {
    await writeDataFile('settings', { ...s, llm: remark(s.llm) });
    void kvSet('meta', 'settings', s); // best effort, dev convenience
    return;
  }
  await kvSet('meta', 'settings', s);
}
