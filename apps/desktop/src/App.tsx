import { useEffect, useRef, useState } from 'react';
import type { FeedId } from '@hackdigest/core';
import { useSettings, useUI, applyChrome } from './state/store';
import Sidebar from './components/Sidebar';
import StoryList from './components/StoryList';
import StoryDetail from './components/StoryDetail';
import SearchPage from './components/SearchPage';
import BookmarksPage from './components/BookmarksPage';
import DailyDigest from './components/DailyDigest';
import SettingsPage from './components/SettingsPage';
import UpdateBanner, { useStartupUpdateCheck } from './components/UpdateBanner';
import ToastHost from './components/Toast';
import ShortcutsOverlay from './components/ShortcutsOverlay';
import StatusBar from './components/StatusBar';
import { isTypingTarget } from './lib/keys';

const FEED_KEYS: Array<'top' | 'new' | 'best' | 'ask' | 'show' | 'job'> = ['top', 'new', 'best', 'ask', 'show', 'job'];

export default function App() {
  const view = useUI((s) => s.view);
  const navigate = useUI((s) => s.navigate);
  const settings = useSettings((s) => s.settings);
  const loaded = useSettings((s) => s.loaded);
  const init = useSettings((s) => s.init);
  const update = useStartupUpdateCheck();
  const [bannerDismissed, setBannerDismissed] = useState(false);
  const [showShortcuts, setShowShortcuts] = useState(false);
  // Keep the feed list mounted (hidden) while a story detail is open on top
  // of it, so feed selection and scroll survive Back exactly as they were.
  const lastFeed = useRef<FeedId>('top');
  const feedEverMounted = useRef(false);
  const viewIsFeed = view.type === 'feed';
  useEffect(() => {
    if (viewIsFeed) {
      lastFeed.current = view.feed;
      feedEverMounted.current = true;
    }
  }, [viewIsFeed, view]);
  const feedMounted = feedEverMounted.current;

  // Global keys: 1-6 switch feeds, / focuses search, ? shows the cheat sheet.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isTypingTarget(e) || e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === '?') {
        setShowShortcuts((v) => !v);
      } else if (e.key === '/') {
        e.preventDefault();
        document.getElementById('global-search')?.focus();
      } else if (e.key === 'Escape') {
        setShowShortcuts(false);
        (document.activeElement as HTMLElement | null)?.blur?.();
      } else if (/^[1-6]$/.test(e.key)) {
        navigate({ type: 'feed', feed: FEED_KEYS[Number(e.key) - 1] });
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [navigate]);

  useEffect(() => {
    void init();
  }, [init]);

  useEffect(() => {
    if (loaded) applyChrome(settings);
  }, [loaded, settings]);

  // Re-resolve "auto" theme when the OS switches.
  useEffect(() => {
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const onChange = () => applyChrome(useSettings.getState().settings);
    mq.addEventListener('change', onChange);
    return () => mq.removeEventListener('change', onChange);
  }, []);

  if (!loaded) return <div className="h-screen w-screen bg-bg" />;

  return (
    <div className="flex h-screen w-screen flex-col overflow-hidden bg-bg text-ink">
      {update && !bannerDismissed && <UpdateBanner update={update} onClose={() => setBannerDismissed(true)} />}
      <div className="flex min-h-0 flex-1">
        <Sidebar />
        <main className="flex h-full min-w-0 flex-1 flex-col overflow-hidden">
          <div className="relative min-h-0 flex-1">
            {feedMounted && (
              <div
                className={`absolute inset-0 overflow-y-auto ${viewIsFeed ? '' : 'invisible'}`}
                aria-hidden={!viewIsFeed}
              >
                <StoryList key={lastFeed.current} feed={lastFeed.current} active={viewIsFeed} />
              </div>
            )}
            {view.type === 'story' && (
              <div className="absolute inset-0 overflow-y-auto">
                <StoryDetail key={view.id} id={view.id} />
              </div>
            )}
            {view.type === 'search' && (
              <div className="absolute inset-0 overflow-y-auto">
                <SearchPage key={view.query} query={view.query} />
              </div>
            )}
            {view.type === 'bookmarks' && (
              <div className="absolute inset-0 overflow-y-auto">
                <BookmarksPage />
              </div>
            )}
            {view.type === 'daily' && (
              <div className="absolute inset-0 overflow-y-auto">
                <DailyDigest />
              </div>
            )}
            {view.type === 'settings' && (
              <div className="absolute inset-0 overflow-y-auto">
                <SettingsPage />
              </div>
            )}
          </div>
          <StatusBar />
        </main>
      </div>
      {showShortcuts && <ShortcutsOverlay onClose={() => setShowShortcuts(false)} />}
      <ToastHost />
    </div>
  );
}
