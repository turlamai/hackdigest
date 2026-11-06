import { describe, expect, it } from 'vitest';
import { sanitizeHtml } from '../src/sanitize';
import { extractJson, langName } from '../src/translate';
import { miniMarkdown, timeAgo, domainOf } from '../src/util';
import { mergeStoredSettings } from '../src/settings';

describe('extractJson (LLM output tolerance)', () => {
  it('parses bare JSON', () => {
    expect(extractJson('{"title":"你好"}')).toEqual({ title: '你好' });
  });
  it('parses fenced JSON', () => {
    expect(extractJson('```json\n{"a":1}\n```')).toEqual({ a: 1 });
  });
  it('parses JSON wrapped in prose', () => {
    expect(extractJson('Here is the translation: {"t":{}} hope it helps')).toEqual({ t: {} });
  });
  it('throws when no object present', () => {
    expect(() => extractJson('no json here')).toThrow();
  });
});

describe('sanitizeHtml (HN text + LLM output)', () => {
  it('keeps allowed tags and text', () => {
    const out = sanitizeHtml('<p>hello <code>x=1</code> <a href="https://a.com">a</a></p>');
    expect(out).toContain('<code>x=1</code>');
    expect(out).toContain('href="https://a.com"');
    expect(out).toContain('rel="noopener noreferrer"');
  });
  it('strips script tags but keeps inner text gone', () => {
    const out = sanitizeHtml('<p>ok</p><script>alert(1)</script>');
    expect(out).not.toContain('script');
    expect(out).toContain('<p>ok</p>');
  });
  it('strips event handler attributes', () => {
    const out = sanitizeHtml('<p onclick="evil()">hi</p>');
    expect(out).not.toContain('onclick');
    expect(out).toContain('hi');
  });
  it('drops javascript: hrefs', () => {
    const out = sanitizeHtml('<a href="javascript:alert(1)">x</a>');
    expect(out).not.toContain('javascript:');
  });
});

describe('miniMarkdown (digest rendering)', () => {
  it('renders headers, lists, bold, code, links', () => {
    const html = miniMarkdown('## 标题\n- **粗体** 和 `代码`\n[链接](https://x.com)');
    expect(html).toContain('<h3>标题</h3>');
    expect(html).toContain('<li><strong>粗体</strong> 和 <code>代码</code></li>');
    expect(html).toContain('<a href="https://x.com"');
  });
  it('escapes raw html in markdown source', () => {
    const html = miniMarkdown('text <img src=x onerror=alert(1)>');
    expect(html).not.toContain('<img');
    expect(html).toContain('&lt;img');
  });
});

describe('timeAgo / domainOf', () => {
  it('formats zh ranges', () => {
    const now = Math.floor(Date.now() / 1000);
    expect(timeAgo(now - 30, 'zh')).toBe('30 秒前');
    expect(timeAgo(now - 5 * 60, 'zh')).toBe('5 分钟前');
    expect(timeAgo(now - 3 * 3600, 'zh')).toBe('3 小时前');
    expect(timeAgo(now - 2 * 86400, 'zh')).toBe('2 天前');
  });
  it('formats en ranges', () => {
    const now = Math.floor(Date.now() / 1000);
    expect(timeAgo(now - 90, 'en')).toBe('1m ago');
  });
  it('extracts domains and strips www', () => {
    expect(domainOf('https://www.example.com/a?b=1')).toBe('example.com');
    expect(domainOf('https://openai.com')).toBe('openai.com');
    expect(domainOf(undefined)).toBeNull();
    expect(domainOf('not a url')).toBeNull();
  });
});

describe('langName', () => {
  it('maps known codes', () => {
    expect(langName('zh')).toContain('Chinese');
    expect(langName('xx')).toBe('xx');
  });
});

describe('mergeStoredSettings (legacy hosted-provider data compatibility)', () => {
  const legacyHosted = {
    providerId: 'hosted',
    llm: { baseUrl: 'https://hd.jrtx.site/v1', apiKey: 'hd_pro_abc', model: 'hosted' },
    hostedStatus: { plan: 'pro', expiresAt: 1, used: 2, limit: 3 },
  } as never;

  it('remaps the removed hosted preset to a working custom endpoint', () => {
    const s = mergeStoredSettings(legacyHosted);
    expect(s.providerId).toBe('custom');
    expect(s.llm).toEqual({ baseUrl: 'https://hd.jrtx.site/v1', apiKey: 'hd_pro_abc', model: 'hosted' });
    expect((s as Record<string, unknown>).hostedStatus).toBeUndefined();
  });

  it('leaves regular stored settings untouched', () => {
    const s = mergeStoredSettings({
      uiLang: 'en',
      providerId: 'glm',
      llm: { baseUrl: 'https://open.bigmodel.cn/api/paas/v4', apiKey: '__SAVED__', model: 'glm-4.6' },
      shortcuts: { listNext: 'J' },
    } as never);
    expect(s.providerId).toBe('glm');
    expect(s.llm?.apiKey).toBe('__SAVED__');
    expect(s.uiLang).toBe('en');
    expect(s.shortcuts.listNext).toBe('J');
    expect(s.shortcuts.listPrev).toBe('k'); // default fills the rest
  });

  it('normalizes a keyless keyring-mode llm so inputs stay controlled', () => {
    const s = mergeStoredSettings({
      providerId: 'custom',
      apiKeyStorage: 'keyring',
      llm: { baseUrl: 'https://x/v1', model: 'm' }, // no apiKey field: key is in the keyring
    } as never);
    expect(s.apiKeyStorage).toBe('keyring');
    expect(s.llm?.baseUrl).toBe('https://x/v1');
    expect(s.llm?.apiKey).toBe('');
    expect(s.llm?.model).toBe('m');
  });

  it('returns defaults for empty input', () => {
    const s = mergeStoredSettings(null);
    expect(s.providerId).toBe('');
    expect(s.autoTranslateTitles).toBe(true);
  });
});
