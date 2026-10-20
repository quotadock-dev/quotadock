import { useEffect, useState } from 'react';
import { translate, useLanguage } from './locale';
import { english } from './translations';

// The bridge has no billing session; this comparison never starts checkout.
export function PlansPage() {
  const { language, control } = useLanguage();
  const t = (value: string) => translate(value, language, english);
  useEffect(() => { document.title = `QuotaDock · ${t('요금제')}`; }, [language]);
  const [cycle, setCycle] = useState('month');
  const annual = cycle === 'year';
  const price = (monthly: number) => new Intl.NumberFormat(language === 'ko' ? 'ko-KR' : 'en-US', { style: 'currency', currency: 'KRW', maximumFractionDigits: 0 }).format(monthly * (annual ? 10 : 1));
  const period = t(annual ? '/ 년' : '/ 월');
  const plans = [
    { name: 'Free', price: t('무료'), period: '', features: ['AI 계정 최대 3개', '수집기 컴퓨터 최대 1대'] },
    { name: 'Plus', price: price(2990), period, features: ['AI 계정 최대 10개', '수집기 컴퓨터 최대 3대'] },
    { name: 'Pro', price: price(5990), period, features: ['AI 계정 최대 25개', '수집기 컴퓨터 최대 5대'] },
  ];
  return <div className="shell plans-shell">
    <header className="masthead"><a className="brand" href="/">QuotaDock</a>{control}</header>
    <main className="plans-page">
      <div className="plans-heading"><h1>{t('요금제')}</h1></div>
      <label>{t('결제 주기')} <select aria-label={t('결제 주기')} value={cycle} onChange={event => setCycle(event.target.value)}><option value="month">{t('월간')}</option><option value="year">{t('연간')}</option></select></label>
      <p>{t('여러 AI 계정과 수집기 컴퓨터를 관리하는 요금제입니다.')}</p>
      <div className="plan-cards">{plans.map(plan => <article className="plan-card" key={plan.name} aria-labelledby={`plan-${plan.name}`}>
        <h2 id={`plan-${plan.name}`}>QuotaDock {plan.name}</h2>
        <p className="plan-price">{plan.price} <span>{plan.period}</span></p>
        <ul>{plan.features.map(feature => <li key={feature}>{t(feature)}</li>)}</ul>
        {plan.name === 'Free' ? <p>{t('기간 제한 없이 무료')}</p> : <p>{t('첫 구매 시 결제:')} {price(plan.name === 'Plus' ? 2990 : 5990)} {period} · {t('자동 갱신')}</p>}
      </article>)}</div>
      <p className="plans-note">{t('새 관측에는 온라인 로컬 수집기가 필요해요. AI 서비스 요금은 별도예요.')}</p>
      <p className="plans-note">{t('QuotaDock Plus는 ChatGPT Plus가 아닙니다.')}</p>
      <details className="plan-terms"><summary>{t('결제 안내·약관')}</summary>
        <p>{t('유료 구독은 무료 체험 없이 첫 구매부터 결제됩니다. 연간 요금은 첫 구매 시 1년 전액이 청구됩니다. 표시 가격은 KRW 안내이며 실제 가격은 Apple StoreKit에서 확인하세요.')}</p>
        <p>{t('선택한 월간 또는 연간 주기로 자동 갱신됩니다. Apple 구독 설정에서 해지하세요. 앱 계정 삭제는 구독 해지가 아닙니다.')}</p>
        <div className="plan-links"><a href="https://usage.mvtp.cloud/#privacy">{t('개인정보')}</a><a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">{t('이용약관')}</a></div>
      </details>
      <a className="plans-back" href="/">← {t('사용량 보드')}</a>
    </main>
  </div>;
}
