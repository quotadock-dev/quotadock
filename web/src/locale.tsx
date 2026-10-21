import { useEffect, useState } from 'react';

export type Language = 'en' | 'ko';
type Preference = Language | 'system';
const key = 'quotadock.language';
const systemLanguage = (): Language => {
  const languages = navigator.languages?.length ? navigator.languages : [navigator.language];
  for (const locale of languages) {
    const language = locale.toLowerCase().split('-')[0];
    if (language === 'en' || language === 'ko') return language;
  }
  return 'en';
};
const valid = (value: string | null): Preference => value === 'en' || value === 'ko' ? value : 'system';
const korean: Readonly<Record<string, string>> = { 'YOUR AI, AT A GLANCE': '내 AI 사용량을 한눈에', 'DEMO · SAMPLE DATA': 'DEMO · 예시 데이터', 'BRIDGE · ERROR': '브리지 · 오류', 'BRIDGE PAIRED': '브리지 연결됨', 'NOT CONNECTED': '연결되지 않음', 'STALE': '오래됨 · STALE', 'LIVE': '최근 관측' };
export function useLanguage() {
  const [preference, setPreference] = useState<Preference>(() => { try { return valid(localStorage.getItem(key)); } catch { return 'system'; } });
  const [saveFailed, setSaveFailed] = useState(false);
  const [system, setSystem] = useState(systemLanguage);
  const language = preference === 'system' ? system : preference;
  useEffect(() => {
    const changed = () => setSystem(systemLanguage());
    const stored = (event: StorageEvent) => {
      try {
        if (event.storageArea === localStorage && (event.key === key || event.key === null)) setPreference(valid(event.newValue));
      } catch { /* Storage access may be blocked; keep the current preference. */ }
    };
    window.addEventListener('languagechange', changed); window.addEventListener('storage', stored);
    return () => { window.removeEventListener('languagechange', changed); window.removeEventListener('storage', stored); };
  }, []);
  useEffect(() => { document.documentElement.lang = language; document.title = language === 'ko' ? 'Allowmark · 사용량 보드' : 'Allowmark · Quota board'; }, [language]);
  const control = <div className="language-setting"><label className="setting">{language === 'ko' ? '언어' : 'Language'} <select aria-label={language === 'ko' ? '언어' : 'Language'} aria-describedby={saveFailed ? 'language-save-status' : undefined} value={preference} onChange={event => {
    const next = valid(event.target.value); setPreference(next);
    try { localStorage.setItem(key, next); setSaveFailed(false); } catch { setSaveFailed(true); }
  }}><option value="system">{language === 'ko' ? '시스템 기본값' : 'System default'}</option><option value="en">English</option><option value="ko">한국어</option></select></label>
    <p id="language-save-status" role={saveFailed ? 'status' : undefined} aria-live="polite" className="small">{saveFailed ? language === 'ko' ? '언어 설정을 저장하지 못했습니다. 새로고침하면 선택이 유지되지 않을 수 있습니다.' : 'Could not save your language. Your choice may reset on reload.' : ''}</p>
  </div>;
  return { language, control };
}

// Only explicitly selected UI labels are translated; upstream data stays raw.
export function translate(value: string, language: Language, dictionary: Readonly<Record<string, string>>): string {
  return language === 'ko' ? korean[value] ?? (value === 'DEMO · STALE' ? 'DEMO · 오래됨 · STALE' : value) : dictionary[value] ?? value;
}
