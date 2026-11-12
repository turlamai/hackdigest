// Durable JSON data files via the Glaze backend (app data dir). The source
// of truth in the packaged app — IndexedDB there proved non-persistent.
// Falls back to null/no-op in plain browsers (dev mode keeps IndexedDB).

import { apiPost, hasBackend } from './bridge';

export type DataFileName = 'settings' | 'library';

export async function readDataFile<T>(name: DataFileName): Promise<T | null> {
  if (!(await hasBackend())) return null;
  try {
    const { json } = await apiPost<{ json: string | null }>('/api/data/read', { name });
    return json ? (JSON.parse(json) as T) : null;
  } catch {
    return null;
  }
}

export async function writeDataFile(name: DataFileName, data: unknown): Promise<boolean> {
  if (!(await hasBackend())) return false;
  try {
    await apiPost('/api/data/write', { name, json: JSON.stringify(data) });
    return true;
  } catch {
    return false;
  }
}
